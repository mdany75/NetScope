import AppKit
import NetScopeCore
import SwiftUI

// Note 69 : vues du scan UDP ciblé. Section « Services UDP » de la fiche Appareil (onglet Ports
// et services), feuille du menu du Scanner « Scanner les ports › UDP ciblé… » et outil Scan de
// ports (protocole « UDP ciblé »). Tableau standard : port, proto, état, service, réponse, délai,
// constat ; facultatives : détails, relevé à.

// MARK: - Tableau

struct UDPResultsTable: View {
    let rows: [UDPProbeResult]
    @ObservedObject var table: StandardTableModel<UDPProbeResult>
    /// Heure du scan (nil : scan en cours).
    var probedAt: Date? = nil
    var maxRows = ToolTableMetrics.maxRows
    var emptyText = "Aucun résultat pour l’instant."

    /// `showProto` : colonne Proto visible par défaut (fiche Appareil, comme les ports TCP).
    static func columns(showProto: Bool) -> [StandardColumn] { [
        StandardColumn(id: "port", title: "Port", isRequired: true),
        StandardColumn(id: "proto", title: "Proto", isDefaultVisible: showProto),
        StandardColumn(id: "etat", title: "État"),
        StandardColumn(id: "service", title: "Service"),
        StandardColumn(id: "reponse", title: "Réponse / version"),
        StandardColumn(id: "delai", title: "Délai"),
        StandardColumn(id: "constat", title: "Constat"),
        StandardColumn(id: "details", title: "Détails", isDefaultVisible: false),
        StandardColumn(id: "releve", title: "Relevé à", isDefaultVisible: false),
    ] }

    static let sortKeys: [String: KeyPathComparator<UDPProbeResult>] = [
        "port": KeyPathComparator(\UDPProbeResult.port),
        "proto": KeyPathComparator(\UDPProbeResult.udpSortProto),
        "etat": KeyPathComparator(\UDPProbeResult.udpSortState),
        "service": KeyPathComparator(\UDPProbeResult.udpSortService),
        "reponse": KeyPathComparator(\UDPProbeResult.udpSortReply),
        "delai": KeyPathComparator(\UDPProbeResult.udpSortDelay),
        "constat": KeyPathComparator(\UDPProbeResult.udpSortFinding),
        "details": KeyPathComparator(\UDPProbeResult.udpDetails),
    ]

    @MainActor
    static func makeModel(id: String, showProto: Bool = true) -> StandardTableModel<UDPProbeResult> {
        StandardTableModel(id: id, columns: columns(showProto: showProto), sortKeys: sortKeys, defaultSort: "port")
    }

    private var protoVisibility: Visibility {
        table.columns.first { $0.id == "proto" }?.isDefaultVisible == true ? .automatic : .hidden
    }

    var body: some View {
        let sorted = rows.sorted(using: table.sortOrder)
        ToolStandardTableFrame(rowCount: sorted.count, maxRows: maxRows, emptyText: emptyText) {
            Table(sorted, sortOrder: $table.sortOrder, columnCustomization: $table.customization) {
                TableColumn("PORT", sortUsing: table.sort("port")) { result in
                    ToolTableText(String(result.port), weight: .semibold)
                }
                .width(min: 58, ideal: 60, max: 64)
                .customizationID("port")
                .disabledCustomizationBehavior(.visibility)

                TableColumn("PROTO", sortUsing: table.sort("proto")) { _ in
                    ToolTableText("udp")
                }
                .width(min: 50, ideal: 54, max: 56)
                .customizationID("proto")
                .defaultVisibility(protoVisibility)

                TableColumn("ÉTAT", sortUsing: table.sort("etat")) { result in
                    Chip(text: result.state.label, tone: result.state.udpTone)
                        .help(result.state.udpHelp)
                }
                .width(min: 70, ideal: 86, max: 96)
                .customizationID("etat")

                TableColumn("SERVICE", sortUsing: table.sort("service")) { result in
                    ToolTableText(result.service.serviceName)
                        .help(result.service.label + " · sonde\u{00A0}: " + result.service.probeDescription)
                }
                .width(min: 56, ideal: 74, max: 96)
                .customizationID("service")

                TableColumn("RÉPONSE / VERSION", sortUsing: table.sort("reponse")) { result in
                    ToolTableText(result.udpReplyText, color: result.summary == nil ? Theme.textTertiary : Theme.textSecondary)
                        .help(([result.summary].compactMap { $0 } + result.details).joined(separator: "\n"))
                }
                .width(min: 110, ideal: 130)
                .customizationID("reponse")

                TableColumn("DÉLAI", sortUsing: table.sort("delai")) { result in
                    ToolTableText(result.rttMs.map(ToolFormat.milliseconds) ?? "—", alignment: .trailing)
                }
                .width(min: 44, ideal: 56, max: 70)
                .customizationID("delai")

                TableColumn("CONSTAT", sortUsing: table.sort("constat")) { result in
                    if let worst = result.findings.min(by: { $0.severity < $1.severity }) {
                        Chip(text: worst.severity.label, tone: worst.severity.tone)
                            .help(result.findings.map { $0.title + "\u{00A0}: " + $0.detail }.joined(separator: "\n\n"))
                    } else {
                        Text("—").font(Theme.small).foregroundStyle(Theme.textTertiary)
                    }
                }
                .width(min: 52, ideal: 60, max: 72)
                .customizationID("constat")

                TableColumn("DÉTAILS", sortUsing: table.sort("details")) { result in
                    ToolTableText(result.udpDetails.isEmpty ? "—" : result.udpDetails, color: Theme.textSecondary)
                        .help(result.details.joined(separator: "\n"))
                }
                .width(min: 100, ideal: 260)
                .customizationID("details")
                .defaultVisibility(.hidden)

                TableColumn("RELEVÉ À") { _ in
                    ToolTableText(probedAt.map { ToolText.time($0) } ?? "—",
                                  color: probedAt == nil ? Theme.textTertiary : Theme.textSecondary)
                }
                .width(min: 60, ideal: 90)
                .customizationID("releve")
                .defaultVisibility(.hidden)
            }
        }
    }
}

extension UDPProbeResult {
    /// Clé de tri de « Proto » (keyPath distinct de « Port » : chaque colonne garde sa flèche).
    var udpSortProto: UInt16 { port }
    var udpSortState: Int { state.rank }
    var udpSortService: String { service.serviceName }
    var udpSortReply: String { summary ?? "~" }
    var udpSortDelay: Double { rttMs ?? .infinity }
    /// Les plus graves d'abord (élevé 0, moyen 1, faible 2, aucun 3).
    var udpSortFinding: Int {
        guard let worst = findings.min(by: { $0.severity < $1.severity }) else { return 3 }
        return worst.severity == .eleve ? 0 : worst.severity == .moyen ? 1 : 2
    }
    var udpDetails: String { details.joined(separator: " · ") }

    /// Texte de la colonne Réponse : la réponse lue, sinon ce que dit l'état.
    var udpReplyText: String {
        if let summary { return summary }
        switch state {
        case .open: return "Réponse reçue"
        case .openFiltered: return "Aucune réponse (service muet ou pare-feu)"
        case .closed: return "Port injoignable (ICMP)"
        case .filtered: return "Interdit par un pare-feu (ICMP)"
        }
    }
}

extension UDPPortState {
    var udpTone: Tone {
        switch self {
        case .open: return .success
        case .openFiltered, .filtered: return .warning
        case .closed: return .neutral
        }
    }

    var udpHelp: String {
        switch self {
        case .open: return "Le service a répondu à la sonde."
        case .openFiltered: return "Aucune réponse après deux envois\u{00A0}: service qui ignore la sonde, ou pare-feu qui jette les paquets. UDP ne permet pas de trancher."
        case .closed: return "L’hôte a répondu «\u{00A0}port injoignable\u{00A0}» (ICMP)\u{00A0}: rien n’écoute."
        case .filtered: return "Un routeur ou un pare-feu a répondu «\u{00A0}interdit\u{00A0}» (ICMP)."
        }
    }
}

extension UDPFinding.Severity {
    var tone: Tone {
        switch self {
        case .eleve: return .critical
        case .moyen: return .warning
        case .faible: return .neutral
        }
    }
}

// MARK: - Constats

struct UDPFindingsList: View {
    let findings: [UDPFinding]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(findings) { finding in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Chip(text: finding.severity.label, tone: finding.severity.tone)
                        .frame(width: 58, alignment: .leading)
                    (Text(finding.title).font(Theme.bodySemibold) + Text(" — " + finding.detail).font(Theme.small).foregroundColor(Theme.textSecondary))
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
        }
    }
}

// MARK: - Choix des sondes

/// Menu « Sondes » : services cochés, communauté SNMP v2c, tests de sécurité NTP.
struct UDPProbeOptionsMenu: View {
    @ObservedObject private var model = UDPScanModel.shared

    var body: some View {
        Menu {
            Section("Services sondés") {
                ForEach(UDPService.ordered) { service in
                    Toggle("\(service.label) · \(service.port)", isOn: Binding(get: { model.services.contains(service) },
                                                                               set: { _ in model.toggle(service) }))
                }
                Button("Tout cocher") { model.services = Set(UDPService.allCases) }
                    .disabled(model.services.count == UDPService.allCases.count)
            }
            Section("Communauté SNMP v2c") {
                Picker("Communauté SNMP v2c", selection: $model.community) {
                    ForEach(UDPCommunityChoice.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
            Section("NTP") {
                Toggle("Tests de sécurité NTP (modes 6 et 7, monlist)", isOn: $model.ntpChecks)
            }
        } label: {
            Text("Sondes\u{00A0}: " + model.servicesLabel).font(.system(size: 12))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Services sondés, communauté SNMP v2c (jamais «\u{00A0}public\u{00A0}» sans votre choix) et tests NTP")
    }
}

// MARK: - Section de la fiche Appareil et feuille du Scanner

struct UDPServicesPanel: View {
    @ObservedObject private var model = UDPScanModel.shared
    let host: String
    let name: String
    /// Dans la feuille du Scanner (sans cadre).
    var inSheet = false

    @StateObject private var table = UDPResultsTable.makeModel(id: "appareil.udp")

    private var hostState: UDPHostState { model.state(for: host) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    heading.fixedSize()
                    Spacer(minLength: 8)
                    controls
                }
                VStack(alignment: .leading, spacing: 10) {
                    heading
                    HStack(spacing: 10) {
                        Spacer(minLength: 0)
                        controls
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            if hostState.isRunning {
                ProgressBar(fraction: hostState.fraction).padding(.horizontal, 16).padding(.bottom, 10)
            }
            if let error = hostState.error {
                ToolNotice(tone: .critical, message: error).padding(.horizontal, 16).padding(.bottom, 10)
            }
            if hostState.isRunning || hostState.summary != nil {
                UDPResultsTable(rows: hostState.rows, table: table, probedAt: hostState.isRunning ? nil : hostState.summary?.date,
                                maxRows: inSheet ? 9 : ToolTableMetrics.maxRows)
                    .padding(.horizontal, 16)
            }
            footer.padding(16)
        }
        .background {
            if !inSheet { RoundedRectangle(cornerRadius: Theme.panelRadius).fill(Theme.panel) }
        }
        .overlay {
            if !inSheet { RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border) }
        }
    }

    private var heading: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            if !inSheet { Text("Services UDP").font(.system(size: 14, weight: .semibold)).fixedSize() }
            Text(subtitle).font(Theme.small).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var subtitle: String {
        if hostState.isRunning {
            return "Scan UDP ciblé en cours · \(hostState.done) / \(hostState.total) ports"
        }
        guard let summary = hostState.summary else {
            return inSheet ? "Lancé seulement sur clic" : "Scan UDP ciblé (DNS, NTP, SNMP, SIP, IPMI…), lancé seulement sur clic"
        }
        // « ouvert|filtré » ne se coupe pas au « | » (gluon U+2060 de part et d'autre).
        var parts = ["Dernier scan\u{00A0}: \(ToolText.time(summary.date))", summary.summary.replacingOccurrences(of: "|", with: "\u{2060}|\u{2060}")]
        if let note = hostState.communityNote, summary.results.contains(where: { $0.service == .snmp }) { parts.append("SNMP\u{00A0}: " + note) }
        return (summary.wasCancelled ? "Interrompu · " : "") + parts.joined(separator: " · ")
    }

    private var controls: some View {
        HStack(spacing: 10) {
            UDPProbeOptionsMenu()
            ToolColumnsMenu(model: table)
            Button("Copier CSV") { model.copyCSV(host: host) }
                .buttonStyle(.secondary)
                .disabled(hostState.summary == nil)
            if hostState.isRunning {
                Button("Arrêter") { model.cancel(host: host) }.buttonStyle(.secondary)
            } else {
                Button(hostState.summary == nil ? "Scanner en UDP" : "Relancer") { model.scan(host: host) }
                    .buttonStyle(.primary)
                    .help("Une sonde propre à chaque protocole\u{00A0}: " + model.orderedServices.map { "\($0.label) \($0.port)" }.joined(separator: ", "))
            }
        }
        .fixedSize()
    }

    @ViewBuilder private var footer: some View {
        let findings = hostState.summary?.findings ?? []
        if findings.isEmpty {
            Text(hostState.summary == nil
                 ? "Chaque port reçoit une vraie requête de son protocole (version.bind, NTP mode 3, découverte SNMP v3, OPTIONS SIP, IPMI RMCP…)\u{00A0}: «\u{00A0}ouvert|filtré\u{00A0}» veut dire aucune réponse, «\u{00A0}fermé\u{00A0}» un refus ICMP."
                 : "Aucun constat de sécurité sur les services UDP sondés.")
                .font(Theme.small).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            UDPFindingsList(findings: findings)
        }
    }
}

// MARK: - Feuille du Scanner

extension View {
    /// Feuille « Scan UDP ciblé » du menu du Scanner, une seule pour toute la fenêtre.
    func udpScanPrompt() -> some View {
        modifier(UDPScanPresenter())
    }
}

private struct UDPScanPresenter: ViewModifier {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var model = UDPScanModel.shared

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) { snapshotSheet }
            .sheet(item: $model.target) { target in
                UDPScanSheet(target: target, dismiss: { model.target = nil })
            }
    }

    /// Captures (NETSCOPE_UDP_FEUILLE) : la feuille dessinée par-dessus la fiche Appareil.
    @ViewBuilder private var snapshotSheet: some View {
        if UDPScanDemo.showsSheet, state.screen == .appareil, let device = state.selectedDevice {
            ZStack(alignment: .top) {
                Color(nsColor: .shadowColor).opacity(0.18).ignoresSafeArea()
                UDPScanSheet(target: UDPScanTarget(device: device), dismiss: {})
                    .clipShape(RoundedRectangle(cornerRadius: Theme.panelRadius))
                    .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
                    .shadow(color: Color(nsColor: .shadowColor).opacity(0.3), radius: 18, y: 8)
                    .padding(.top, 8)
            }
        }
    }
}

struct UDPScanSheet: View {
    let target: UDPScanTarget
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.accentSoft)
                    Image(systemName: "dot.radiowaves.left.and.right").font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Theme.accent)
                }
                .frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Scan UDP ciblé de \(target.name)").font(Theme.panelTitle).foregroundStyle(Theme.text)
                        .lineLimit(1).truncationMode(.middle)
                    Text(target.host).font(Theme.small).foregroundStyle(Theme.textSecondary)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            UDPServicesPanel(host: target.host, name: target.name, inSheet: true)
                .padding(.horizontal, 4)
            Divider()
            HStack {
                Spacer()
                Button("Fermer", action: dismiss).buttonStyle(.secondary).keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 860)
        .background(Theme.panel)
    }
}
