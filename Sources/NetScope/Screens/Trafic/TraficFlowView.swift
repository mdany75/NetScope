import NetScopeCore
import SwiftUI

// Source « Flux » de l'écran Trafic (note 75) : collecteur NetFlow, sFlow et IPFIX de ce Mac.
// Barre d'état (démarrer, arrêter), tuiles, « Qui sature le lien ? », charge des liens, tableaux
// (sources, destinations, applications, interfaces, conversations, exportateurs), puis réglages des
// ports et guide de configuration par marque.

struct TraficFlowView: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var flows = FlowStore.shared
    @ObservedObject private var screen = TrafficScreenState.shared
    @ObservedObject private var traffic = TrafficStore.shared

    var body: some View {
        let overview = flows.overview
        VStack(alignment: .leading, spacing: 14) {
            FlowCollectorBar()
            ForEach(flows.startErrors, id: \.self) { message in
                ToolNotice(tone: .critical, title: "Écoute impossible", message: message)
            }
            if let warning = flows.firewall?.flowWarning, flows.isListening {
                ToolNotice(tone: .warning, message: warning)
            }
            if overview.isEmpty {
                ToolNotice(tone: .accent, title: flows.isListening ? "En attente des premiers flux…" : "Collecteur arrêté",
                           message: flows.isListening
                           ? "Réglez l’envoi des flux sur le routeur, le pare-feu ou le switch (guide ci-dessous), vers l’adresse de ce Mac et le port indiqué. Les premiers flux arrivent en général moins d’une minute après (délai d’expiration des flux actifs de l’équipement)."
                           : "Démarrez l’écoute pour recevoir NetFlow, IPFIX ou sFlow des équipements, même sans FortiGate\u{00A0}: «\u{00A0}Qui sature le lien\u{00A0}?\u{00A0}», sources, destinations et applications d’après les flux. Rien n’est écouté tant que vous ne cliquez pas sur «\u{00A0}Démarrer l’écoute\u{00A0}».")
            } else {
                FlowSummaryTiles(overview: overview)
                saturationBanner(overview)
                TrafficLinksPanel(overview: overview)
                FlowTabsView(overview: overview)
                notes(overview)
            }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 14) {
                    FlowPortsPanel().frame(width: 380)
                    FlowGuidePanel().frame(minWidth: 420, idealWidth: 520, maxWidth: .infinity)
                }
                VStack(alignment: .leading, spacing: 14) {
                    FlowPortsPanel()
                    FlowGuidePanel()
                }
            }
        }
        // Appareils nommés comme dans NetScope dès que l'état de l'app est rattaché.
        .onAppear { flows.refresh() }
    }

    @ViewBuilder private func saturationBanner(_ overview: TrafficOverview) -> some View {
        let verdict = TrafficAnalysis.whoSaturates(overview, thresholds: traffic.thresholds)
        if verdict.isSaturated {
            ToolNotice(tone: verdict.link?.level == .critical ? .critical : .warning, title: verdict.headline, message: verdict.advice) {
                Button("Qui sature le lien\u{00A0}?") { screen.showSaturation = true }
                    .buttonStyle(.secondary)
                    .fixedSize()
            }
        }
    }

    @ViewBuilder private func notes(_ overview: TrafficOverview) -> some View {
        if !overview.notes.isEmpty {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(overview.notes, id: \.self) { note in
                        Text("• " + note).font(Theme.small).foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.top, 4)
            } label: {
                Text("Remarques sur les flux (\(overview.notes.count))").font(Theme.small).foregroundStyle(Theme.textSecondary)
            }
        }
    }
}

// MARK: - Barre d'état

struct FlowCollectorBar: View {
    @ObservedObject private var flows = FlowStore.shared

    var body: some View {
        Panel(padding: 12) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    chip
                    texts
                    Spacer(minLength: 8)
                    button
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        chip
                        Spacer(minLength: 8)
                        button
                    }
                    texts
                }
            }
        }
    }

    @ViewBuilder private var chip: some View {
        if flows.isListening {
            Chip(text: flows.isDemo ? "En écoute (démonstration)" : "En écoute", tone: .success, systemImage: "dot.radiowaves.left.and.right")
        } else {
            Chip(text: "Arrêté", tone: .neutral, systemImage: "pause.circle")
        }
    }

    private var texts: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("UDP " + (flows.portsLabel.isEmpty ? "aucun port" : flows.portsLabel))
                .font(Theme.mono(12, weight: .semibold)).foregroundStyle(Theme.text)
                .lineLimit(1)
            Text(detail)
                .font(Theme.small).foregroundStyle(Theme.textSecondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var detail: String {
        var text = flows.countsLabel
        if let last = flows.status.exporters.map(\.lastSeen).max() { text += " · dernier " + ToolText.relative(last) }
        if !flows.isListening, let reason = flows.stopReason { text = reason }
        if flows.status.rejected > 0, let rejection = flows.status.lastRejection, flows.isListening { text += "\nDernier rejet\u{00A0}: " + rejection }
        return text
    }

    private var button: some View {
        Button {
            flows.isListening ? flows.stop() : flows.start()
        } label: {
            Label(flows.isListening ? "Arrêter l’écoute" : "Démarrer l’écoute",
                  systemImage: flows.isListening ? "stop.fill" : "dot.radiowaves.left.and.right")
        }
        .buttonStyle(flows.isListening ? AnyPrimitiveButtonStyle(.secondary) : AnyPrimitiveButtonStyle(.primary))
        .fixedSize()
        .help(flows.isListening ? "Ferme les ports\u{00A0}; les flux déjà reçus restent affichés." : "Ouvre les ports UDP cochés sur toutes les interfaces de ce Mac.")
    }
}

// MARK: - Tuiles

struct FlowSummaryTiles: View {
    @ObservedObject private var flows = FlowStore.shared
    @ObservedObject private var traffic = TrafficStore.shared
    @ObservedObject private var screen = TrafficScreenState.shared
    let overview: TrafficOverview

    var body: some View {
        let rates = TrafficAnalysis.wanRates(overview)
        let usages = TrafficAnalysis.linkUsage(overview, thresholds: traffic.thresholds)
        let worst = usages.first
        let consumers = TrafficAnalysis.consumers(overview, limit: 1)
        let unexpected = TrafficAnalysis.unexpectedApplications(overview)
        let sources = overview.entries(.sources)
        let span = FlowTrafficBridge.span(overview.period)
        let kinds = Set(flows.status.exporters.flatMap(\.kinds)).sorted().map(\.label)
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 175), spacing: 12, alignment: .top)], alignment: .leading, spacing: 12) {
            InvTile(title: "Débit Internet", value: "↓\u{00A0}" + TrafficFormat.rate(rates.rx),
                    subtitle: "↑\u{00A0}" + TrafficFormat.rate(rates.tx) + " · moyenne " + span)
            InvTile(title: "Lien le plus chargé", value: worst?.percent.map(ResourceFormat.percent) ?? "—",
                    subtitle: worst.map { $0.link.label + (overview.isMultiSite ? " · \($0.link.site)" : "") } ?? "Aucun lien Internet reconnu",
                    valueColor: worst?.percent.map { TrafficStyle.color(percent: $0, text: true) } ?? Theme.text,
                    tint: worst?.level == .critical ? .critical : nil) {
                if let percent = worst?.percent {
                    ProgressBar(fraction: percent / 100, color: TrafficStyle.color(percent: percent)).padding(.top, 2)
                }
            }
            InvTile(title: "Premier consommateur", value: consumers.first.map { TrafficFormat.rate($0.entry.bandwidth) } ?? "—",
                    subtitle: consumers.first.map { "\(name($0.entry)) · \(ResourceFormat.percent($0.sharePercent)) du trafic" } ?? "Aucune source",
                    action: consumers.isEmpty ? nil : { screen.showSaturation = true })
            InvTile(title: "Applications", value: "\(overview.entries(.applications).count)",
                    subtitle: unexpected.isEmpty ? "Aucune application inattendue" : "\(unexpected.count) inattendue\(unexpected.count > 1 ? "s" : "")\u{00A0}: " + Self.uniqueNames(unexpected).prefix(2).joined(separator: ", "),
                    valueColor: unexpected.isEmpty ? Theme.text : Theme.warning,
                    action: { flows.tab = .applications })
            InvTile(title: "Exportateurs", value: "\(flows.status.exporters.count)",
                    subtitle: kinds.isEmpty ? "Aucun format reçu" : kinds.joined(separator: ", "),
                    action: { flows.tab = .exporters })
            InvTile(title: "Conversations", value: ToolFormat.integer(overview.sessions.count),
                    subtitle: "\(sources.count) appareil\(sources.count > 1 ? "s" : "") actif\(sources.count > 1 ? "s" : "") " + span,
                    action: { flows.tab = .conversations })
        }
    }

    /// Noms sans doublon (la même application vue par deux exportateurs).
    static func uniqueNames(_ entries: [TrafficEntry]) -> [String] {
        var seen = Set<String>()
        return entries.map(\.name).filter { seen.insert($0).inserted }
    }

    @MainActor private func name(_ entry: TrafficEntry) -> String {
        guard let state = traffic.appState else { return entry.name }
        return traffic.displayName(ip: entry.ip, mac: nil, fallback: entry.name, site: entry.site, state: state)
    }
}

// MARK: - Ports

struct FlowPortsPanel: View {
    @ObservedObject private var flows = FlowStore.shared
    @State private var netflowText = ""
    @State private var ipfixText = ""
    @State private var sflowText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            MonHeading("Collecteur de ce Mac")
            row(title: "NetFlow", detail: "v5 et v9 (Cisco, FortiGate, MikroTik, EdgeRouter)", enabled: $flows.ports.netflowEnabled,
                text: $netflowText, standard: 2055) { flows.ports.netflow = $0 }
            row(title: "IPFIX", detail: "RFC\u{00A0}7011 (Cisco, MikroTik, Juniper)", enabled: $flows.ports.ipfixEnabled,
                text: $ipfixText, standard: 4739) { flows.ports.ipfix = $0 }
            row(title: "sFlow", detail: "v5 (HP/Aruba, FortiSwitch, Juniper, Arista)", enabled: $flows.ports.sflowEnabled,
                text: $sflowText, standard: 6343) { flows.ports.sflow = $0 }
            Text("Chaque port accepte les quatre formats (reconnus au premier octet). Ports au-dessus de 1024\u{00A0}: aucun droit administrateur. Les flux restent en mémoire sur ce Mac, 24\u{00A0}h au plus, puis sont oubliés\u{00A0}; rien n’est écrit sur disque.")
                .font(Theme.caption).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if !flows.isDemo {
                Button("Effacer les flux reçus") { flows.clear() }
                    .buttonStyle(.secondary)
                    .controlSize(.small)
                    .fixedSize()
                    .disabled(flows.status.received == 0)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .monPanel()
        .onAppear { showAppliedPorts() }
        // Au démarrage de l'écoute, les champs reprennent les ports réellement appliqués.
        .onChange(of: flows.isListening) { _, _ in showAppliedPorts() }
    }

    private func showAppliedPorts() {
        netflowText = String(flows.ports.netflow)
        ipfixText = String(flows.ports.ipfix)
        sflowText = String(flows.ports.sflow)
    }

    /// Port UDP saisi, s'il est valide (1 à 65535).
    static func port(_ text: String) -> UInt16? {
        UInt16(text.trimmingCharacters(in: .whitespaces)).flatMap { $0 > 0 ? $0 : nil }
    }

    private func row(title: String, detail: String, enabled: Binding<Bool>, text: Binding<String>, standard: UInt16,
                     apply: @escaping (UInt16) -> Void) -> some View {
        HStack(spacing: 8) {
            Toggle(isOn: enabled) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(title).font(Theme.bodySemibold).foregroundStyle(Theme.text)
                    Text(detail).font(Theme.caption).foregroundStyle(Theme.textSecondary).lineLimit(1)
                }
            }
            .toggleStyle(.checkbox)
            .disabled(flows.isListening)
            Spacer(minLength: 6)
            Text("UDP").font(Theme.caption).foregroundStyle(Theme.textSecondary).fixedSize()
            let invalid = Self.port(text.wrappedValue) == nil
            TextField("", text: text)
                .textFieldStyle(.roundedBorder)
                .font(Theme.mono(12))
                .frame(width: 62)
                .disabled(flows.isListening)
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.critical, lineWidth: invalid ? 1.5 : 0))
                .onChange(of: text.wrappedValue) { _, value in
                    if let port = Self.port(value) { apply(port) }
                }
                .help(invalid
                      ? "Port invalide\u{00A0}: de 1 à 65535. Le port appliqué reste l’ancien."
                      : "Port d’écoute de 1 à 65535 (standard\u{00A0}: \(standard))\u{00A0}; modifiable à l’arrêt.")
        }
    }
}

// MARK: - Guide

struct FlowGuidePanel: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var flows = FlowStore.shared
    @State private var brand: FlowDeviceGuide.Brand = FlowDemo.requestedBrand ?? .fortigate

    private var macAddress: String { state.activeInterface?.address.description ?? "<adresse du Mac>" }

    var body: some View {
        let step = FlowDeviceGuide.step(brand, mac: macAddress, ports: flows.ports)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                MonHeading("Guide de configuration")
                Spacer(minLength: 6)
                Chip(text: "\(step.kind.label) · UDP \(step.port)", tone: .accent, mono: true)
            }
            Picker("Équipement", selection: $brand) {
                ForEach(FlowDeviceGuide.Brand.orderedFamilies, id: \.self) { family in
                    Section(family) {
                        ForEach(FlowDeviceGuide.Brand.ordered(in: family)) { item in
                            Text(item.label).tag(item)
                        }
                    }
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
            if !isEnabled(step.kind) {
                Text("Cochez «\u{00A0}\(label(step.kind))\u{00A0}» dans le collecteur pour recevoir ce format.")
                    .font(Theme.caption).foregroundStyle(Theme.warning)
            }
            commandBlock(step.commands, help: step.isInterfacePath ? "Copier le chemin" : "Copier les commandes")
            if let verify = step.verify {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("Vérifier").font(Theme.caption.weight(.semibold)).foregroundStyle(Theme.textSecondary).fixedSize()
                    Text(verify).font(Theme.mono(11)).foregroundStyle(Theme.text).textSelection(.enabled).lineLimit(1)
                    Spacer(minLength: 4)
                    Button { ToolActions.copy(verify) } label: { Image(systemName: "doc.on.doc").font(.system(size: 10)) }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.textSecondary)
                        .help("Copier la commande de vérification")
                }
            }
            if let note = step.note {
                Text(note).font(Theme.caption).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Adresse de ce Mac\u{00A0}: \(macAddress). L’équipement doit joindre ce Mac en UDP (même réseau, ou route et règle de pare-feu vers lui).")
                .font(Theme.caption).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .monPanel()
    }

    private func isEnabled(_ kind: FlowProtocolKind) -> Bool {
        switch kind {
        case .netflow5, .netflow9: return flows.ports.netflowEnabled
        case .ipfix: return flows.ports.ipfixEnabled
        case .sflow: return flows.ports.sflowEnabled
        }
    }

    private func label(_ kind: FlowProtocolKind) -> String {
        switch kind {
        case .netflow5, .netflow9: return "NetFlow"
        case .ipfix: return "IPFIX"
        case .sflow: return "sFlow"
        }
    }

    private func commandBlock(_ text: String, help: String) -> some View {
        ZStack(alignment: .topTrailing) {
            Text(text)
                .font(Theme.mono(11))
                .foregroundStyle(Theme.consoleText)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.console))
            Button { ToolActions.copy(text) } label: {
                Image(systemName: "doc.on.doc").font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.consoleMuted)
            .padding(8)
            .help(help)
        }
    }
}
