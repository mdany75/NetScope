import NetScopeCore
import SwiftUI

/// Onglet « Constats » de la capture de paquets (note 78) : problèmes repérés automatiquement
/// (retransmissions, fenêtre nulle, requêtes sans réponse, échecs, perte et gigue RTP, horloge),
/// latence mesurée par flux et qualité des flux RTP. Un clic sur « Voir les paquets » applique le
/// filtre d'affichage du constat et revient à la liste.
struct PacketFindingsView: View {
    @ObservedObject var model: ToolPacketCaptureModel
    @StateObject private var latencyTable = FlowLatencyTable.makeModel()
    @StateObject private var rtpTable = RTPStreamTable.makeModel()

    var body: some View {
        let report = model.findingsReport()
        VStack(alignment: .leading, spacing: 14) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], spacing: 8) {
                ToolStatTile(label: "Problèmes", value: "\(report.count(.critical))", detail: "à corriger",
                             valueColor: report.count(.critical) > 0 ? Theme.critical : Theme.text)
                ToolStatTile(label: "À surveiller", value: "\(report.count(.warning))", detail: "constats",
                             valueColor: report.count(.warning) > 0 ? Theme.warning : Theme.text)
                ToolStatTile(label: "Flux mesurés", value: "\(report.latencies.count)", detail: "latence requête → réponse")
                ToolStatTile(label: "Flux RTP", value: "\(report.rtpStreams.count)", detail: report.rtpStreams.isEmpty ? "aucune voix sur IP" : "perte et gigue mesurées")
            }
            if report.findings.isEmpty {
                ToolNotice(tone: .success, title: "Aucun problème repéré",
                           message: "Ni retransmission, ni fenêtre nulle, ni requête sans réponse, ni perte de voix dans ces \(PacketText.number(report.packetCount)) paquets. La latence mesurée par flux est ci-dessous.")
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(report.findings.enumerated()), id: \.element.id) { index, finding in
                        if index > 0 { Divider().padding(.leading, 38) }
                        FindingRow(finding: finding) { model.showFinding(finding) }
                    }
                }
                .background(RoundedRectangle(cornerRadius: Theme.panelRadius).fill(Theme.panel))
                .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
            }
            section("Latence par flux · \(report.latencies.count)", table: latencyTable) {
                FlowLatencyTable(rows: report.latencies.map(FlowLatencyRow.init), table: latencyTable)
            }
            if !report.rtpStreams.isEmpty {
                section("Flux RTP (voix et vidéo) · \(report.rtpStreams.count)", table: rtpTable) {
                    RTPStreamTable(rows: report.rtpStreams.map(RTPStreamRow.init), table: rtpTable)
                }
            }
            Text("Constats calculés sur toute la capture. Latence\u{00A0}: temps entre une requête et sa réponse vu depuis ce point de capture (poignée de main TCP, DNS, HTTP, SNMP, RADIUS, NTP, SIP). Gigue RTP selon RFC\u{00A0}3550\u{00A0}; perte d’après les numéros de séquence. Une requête est dite sans réponse si la capture a duré au moins \(Int(CaptureFindingsAnalyzer.answerTimeout))\u{00A0}s de plus.")
                .font(Theme.caption)
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func section<Row: Identifiable, Content: View>(_ title: String, table: StandardTableModel<Row>,
                                                           @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ToolFieldLabel(title)
                Spacer(minLength: 8)
                ToolColumnsMenu(model: table)
            }
            content()
        }
    }
}

/// Une ligne de constat : icône de gravité, titre, explication et bouton vers les paquets.
private struct FindingRow: View {
    let finding: CaptureFinding
    let show: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 18)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(finding.title)
                    .font(Theme.bodySemibold)
                    .foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
                Text(finding.detail)
                    .font(Theme.small)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if finding.filter != nil {
                Button(action: show) {
                    Text(finding.packets.count > 1 ? "Voir les \(finding.packets.count) paquets" : "Voir le paquet")
                }
                .buttonStyle(.secondary)
                .controlSize(.small)
                .fixedSize()
                .help("Filtre d’affichage\u{00A0}: \(finding.filter ?? "")")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var icon: String {
        switch finding.severity {
        case .critical: return "xmark.octagon.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .info: return "info.circle.fill"
        }
    }

    private var color: Color {
        switch finding.severity {
        case .critical: return Theme.critical
        case .warning: return Theme.warning
        case .info: return Theme.accent
        }
    }
}

// MARK: Tableaux

struct FlowLatencyRow: Identifiable {
    let latency: FlowLatency
    var id: String { latency.id }
    var flow: String { latency.flow }
    var measure: String { latency.measure }
    var count: Int { latency.count }
    var minimum: Double { latency.minimum ?? -1 }
    var median: Double { latency.median ?? -1 }
    var maximum: Double { latency.maximum ?? -1 }
    var unanswered: Int { latency.unanswered }
    var failures: Int { latency.failures }

    init(_ latency: FlowLatency) { self.latency = latency }
}

/// Latence par flux (« outils.paquets.latences ») : flux, mesure, échantillons, min, médiane, max,
/// sans réponse, échecs.
struct FlowLatencyTable: View {
    let rows: [FlowLatencyRow]
    @ObservedObject var table: StandardTableModel<FlowLatencyRow>

    static let columns: [StandardColumn] = [
        StandardColumn(id: "flux", title: "Flux", isRequired: true),
        StandardColumn(id: "mesure", title: "Mesure"),
        StandardColumn(id: "mesures", title: "Mesures"),
        StandardColumn(id: "min", title: "Min.", isDefaultVisible: false),
        StandardColumn(id: "mediane", title: "Médiane"),
        StandardColumn(id: "max", title: "Max."),
        StandardColumn(id: "sansReponse", title: "Sans réponse"),
        StandardColumn(id: "echecs", title: "Échecs"),
    ]

    static let sortKeys: [String: KeyPathComparator<FlowLatencyRow>] = [
        "flux": KeyPathComparator(\FlowLatencyRow.flow),
        "mesure": KeyPathComparator(\FlowLatencyRow.measure),
        "mesures": KeyPathComparator(\FlowLatencyRow.count, order: .reverse),
        "min": KeyPathComparator(\FlowLatencyRow.minimum, order: .reverse),
        "mediane": KeyPathComparator(\FlowLatencyRow.median, order: .reverse),
        "max": KeyPathComparator(\FlowLatencyRow.maximum, order: .reverse),
        "sansReponse": KeyPathComparator(\FlowLatencyRow.unanswered, order: .reverse),
        "echecs": KeyPathComparator(\FlowLatencyRow.failures, order: .reverse),
    ]

    @MainActor
    static func makeModel() -> StandardTableModel<FlowLatencyRow> {
        StandardTableModel(id: "outils.paquets.latences", columns: columns, sortKeys: sortKeys, defaultSort: "mediane")
    }

    static func duration(_ value: Double) -> String {
        value < 0 ? "—" : CaptureFindingsAnalyzer.milliseconds(value)
    }

    var body: some View {
        let sorted = rows.sorted(using: table.sortOrder)
        ToolStandardTableFrame(rowCount: sorted.count, maxRows: 8, emptyText: "Aucune requête ni poignée de main TCP dans la capture.") {
            Table(sorted, sortOrder: $table.sortOrder, columnCustomization: $table.customization) {
                TableColumn("FLUX", sortUsing: table.sort("flux")) { row in ToolTableText(row.flow, weight: .semibold).help(row.flow) }
                    .width(min: 150, ideal: 230)
                    .customizationID("flux")
                    .disabledCustomizationBehavior(.visibility)
                TableColumn("MESURE", sortUsing: table.sort("mesure")) { row in
                    HStack(spacing: 6) {
                        PacketProtocolChip(kind: row.latency.kind)
                        ToolTableText(row.measure, color: Theme.textSecondary)
                    }
                    .help(row.measure)
                }
                .width(min: 110, ideal: 170)
                .customizationID("mesure")
                TableColumn("MESURES", sortUsing: table.sort("mesures")) { row in ToolTableText("\(row.count)", alignment: .trailing) }
                    .width(min: 70, ideal: 76)
                    .customizationID("mesures")
                TableColumn("MIN.", sortUsing: table.sort("min")) { row in ToolTableText(Self.duration(row.minimum), alignment: .trailing) }
                    .width(min: 56, ideal: 70)
                    .customizationID("min")
                    .defaultVisibility(.hidden)
                TableColumn("MÉDIANE", sortUsing: table.sort("mediane")) { row in
                    ToolTableText(Self.duration(row.median), weight: .semibold, color: color(row), alignment: .trailing)
                }
                .width(min: 78, ideal: 84)
                .customizationID("mediane")
                TableColumn("MAX.", sortUsing: table.sort("max")) { row in ToolTableText(Self.duration(row.maximum), color: Theme.textSecondary, alignment: .trailing) }
                    .width(min: 60, ideal: 70)
                    .customizationID("max")
                TableColumn("SANS RÉPONSE", sortUsing: table.sort("sansReponse")) { row in
                    ToolTableText(row.unanswered > 0 ? "\(row.unanswered)" : "—", color: row.unanswered > 0 ? Theme.warning : Theme.textTertiary, alignment: .trailing)
                }
                .width(min: 104, ideal: 110)
                .customizationID("sansReponse")
                TableColumn("ÉCHECS", sortUsing: table.sort("echecs")) { row in
                    ToolTableText(row.failures > 0 ? "\(row.failures)" : "—", color: row.failures > 0 ? Theme.warning : Theme.textTertiary, alignment: .trailing)
                }
                .width(min: 64, ideal: 70)
                .customizationID("echecs")
            }
        }
    }

    private func color(_ row: FlowLatencyRow) -> Color {
        guard row.median >= 0 else { return Theme.textTertiary }
        return row.median > CaptureFindingsAnalyzer.latencyThreshold(row.latency.kind, handshake: row.latency.kind == .tcp) ? Theme.warning : Theme.text
    }
}

struct RTPStreamRow: Identifiable {
    let stream: RTPStreamSummary
    var id: String { stream.id }
    var flow: String { stream.label }
    var codec: String { stream.codec }
    var packets: Int { stream.packets }
    var loss: Double { stream.lossRatio }
    var jitter: Double { stream.jitter }
    var maxDelta: Double { stream.maxDelta }
    var duration: Double { stream.duration }
    var ssrc: String { PacketText.hex(stream.ssrc, digits: 8) }
    /// Note 92 : note MOS du sens (modèle E, codec du flux).
    let score: VoIPScore
    var mos: Double { score.mos }

    init(_ stream: RTPStreamSummary) {
        self.stream = stream
        score = VoIPQuality.score(stream: stream)
    }
}

/// Flux RTP (« outils.paquets.rtp ») : flux, SSRC, codec, paquets, perte, gigue, écart max, RTCP.
struct RTPStreamTable: View {
    let rows: [RTPStreamRow]
    @ObservedObject var table: StandardTableModel<RTPStreamRow>

    static let columns: [StandardColumn] = [
        StandardColumn(id: "flux", title: "Flux", isRequired: true),
        StandardColumn(id: "ssrc", title: "SSRC", isDefaultVisible: false),
        StandardColumn(id: "codec", title: "Codec"),
        StandardColumn(id: "paquets", title: "Paquets"),
        StandardColumn(id: "perte", title: "Perte"),
        StandardColumn(id: "gigue", title: "Gigue"),
        StandardColumn(id: "ecart", title: "Écart max."),
        StandardColumn(id: "mos", title: "MOS"),
        StandardColumn(id: "duree", title: "Durée", isDefaultVisible: false),
        StandardColumn(id: "rtcp", title: "Vu par l’autre côté (RTCP)"),
    ]

    static let sortKeys: [String: KeyPathComparator<RTPStreamRow>] = [
        "flux": KeyPathComparator(\RTPStreamRow.flow),
        "ssrc": KeyPathComparator(\RTPStreamRow.ssrc),
        "codec": KeyPathComparator(\RTPStreamRow.codec),
        "paquets": KeyPathComparator(\RTPStreamRow.packets, order: .reverse),
        "perte": KeyPathComparator(\RTPStreamRow.loss, order: .reverse),
        "gigue": KeyPathComparator(\RTPStreamRow.jitter, order: .reverse),
        "ecart": KeyPathComparator(\RTPStreamRow.maxDelta, order: .reverse),
        "mos": KeyPathComparator(\RTPStreamRow.mos),
        "duree": KeyPathComparator(\RTPStreamRow.duration, order: .reverse),
        "rtcp": KeyPathComparator(\RTPStreamRow.loss, order: .reverse),
    ]

    @MainActor
    static func makeModel() -> StandardTableModel<RTPStreamRow> {
        StandardTableModel(id: "outils.paquets.rtp", columns: columns, sortKeys: sortKeys, defaultSort: "perte")
    }

    var body: some View {
        let sorted = rows.sorted(using: table.sortOrder)
        ToolStandardTableFrame(rowCount: sorted.count, maxRows: 6, emptyText: "Aucun flux RTP.") {
            Table(sorted, sortOrder: $table.sortOrder, columnCustomization: $table.customization) {
                TableColumn("FLUX", sortUsing: table.sort("flux")) { row in ToolTableText(row.flow, weight: .semibold).help(row.flow) }
                    .width(min: 160, ideal: 250)
                    .customizationID("flux")
                    .disabledCustomizationBehavior(.visibility)
                TableColumn("SSRC", sortUsing: table.sort("ssrc")) { row in ToolTableText(row.ssrc, color: Theme.textSecondary) }
                    .width(min: 80, ideal: 96)
                    .customizationID("ssrc")
                    .defaultVisibility(.hidden)
                TableColumn("CODEC", sortUsing: table.sort("codec")) { row in ToolTableText(row.codec).help(row.codec) }
                    .width(min: 60, ideal: 120)
                    .customizationID("codec")
                TableColumn("PAQUETS", sortUsing: table.sort("paquets")) { row in ToolTableText(PacketText.number(row.packets), alignment: .trailing) }
                    .width(min: 50, ideal: 64)
                    .customizationID("paquets")
                TableColumn("PERTE", sortUsing: table.sort("perte")) { row in
                    ToolTableText(row.stream.lost > 0 ? "\(CaptureFindingsAnalyzer.percent(row.loss)) (\(row.stream.lost))" : "0\u{00A0}%",
                                  weight: .semibold, color: row.loss >= 0.05 ? Theme.critical : row.loss >= 0.01 ? Theme.warning : Theme.text, alignment: .trailing)
                }
                .width(min: 60, ideal: 90)
                .customizationID("perte")
                TableColumn("GIGUE", sortUsing: table.sort("gigue")) { row in
                    ToolTableText(CaptureFindingsAnalyzer.milliseconds(row.jitter / 1000), color: row.jitter > 30 ? Theme.warning : Theme.text, alignment: .trailing)
                }
                .width(min: 56, ideal: 70)
                .customizationID("gigue")
                TableColumn("ÉCART MAX.", sortUsing: table.sort("ecart")) { row in
                    ToolTableText(CaptureFindingsAnalyzer.milliseconds(row.maxDelta / 1000), color: Theme.textSecondary, alignment: .trailing)
                }
                .width(min: 86, ideal: 92)
                .customizationID("ecart")
                TableColumn("MOS", sortUsing: table.sort("mos")) { row in
                    ToolTableText("\(row.score.mosLabel) · \(row.score.grade.label.lowercased())", weight: .semibold,
                                  color: row.score.grade <= .poor ? Theme.critical : row.score.grade == .fair ? Theme.warning : Theme.success)
                        .help("Modèle E (ITU-T G.107), codec \(row.score.codec), R = \(Int(row.score.rFactor.rounded())) ; délai dans un sens compté à 0 (non visible depuis la capture)")
                }
                .width(min: 90, ideal: 120)
                .customizationID("mos")
                TableColumn("DURÉE", sortUsing: table.sort("duree")) { row in
                    ToolTableText(PacketText.seconds(row.duration, decimals: 1) + "\u{00A0}s", color: Theme.textSecondary, alignment: .trailing)
                }
                .width(min: 50, ideal: 64)
                .customizationID("duree")
                .defaultVisibility(.hidden)
                TableColumn("VU PAR L’AUTRE CÔTÉ (RTCP)", sortUsing: table.sort("rtcp")) { row in
                    ToolTableText(rtcpText(row.stream), color: Theme.textSecondary)
                }
                .width(min: 120, ideal: 190)
                .customizationID("rtcp")
            }
        }
    }

    private func rtcpText(_ stream: RTPStreamSummary) -> String {
        guard let loss = stream.reportedLoss else { return "—" }
        var text = "perte \(CaptureFindingsAnalyzer.percent(loss))"
        if let jitter = stream.reportedJitter { text += ", gigue \(CaptureFindingsAnalyzer.milliseconds(jitter / 1000))" }
        return text
    }
}
