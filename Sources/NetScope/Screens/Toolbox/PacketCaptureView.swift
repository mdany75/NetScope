import NetScopeCore
import SwiftUI

/// Capture et inspection de paquets, façon Wireshark (note 7) : choix de l'interface, filtre de
/// capture et préréglages, limites, liste des paquets en direct, filtre d'affichage, détail par
/// couche, hexadécimal surligné, suivi de flux, statistiques, ouverture et enregistrement en .pcap.
struct PacketCaptureView: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var model: ToolPacketCaptureModel
    @ObservedObject var store: ToolStore
    @StateObject private var packetTable = PacketListTable.makeModel()
    @StateObject private var protocolTable = ProtocolStatsTable.makeModel()
    @StateObject private var conversationTable = ConversationStatsTable.makeModel()
    @StateObject private var talkerTable = TalkerStatsTable.makeModel()

    static let quickFilters: [(String, String)] = [
        ("Problèmes TCP (retransmissions, RST…)", "tcp.analysis.flags || tcp.flags.reset"),
        ("DNS et mDNS", "dns || mdns"),
        ("Web (HTTP et TLS)", "http || tls"),
        ("Négociations TLS (SNI)", "tls.handshake"),
        ("ARP", "arp"),
        ("DHCP", "dhcp"),
        ("Découverte (LLDP, CDP, STP)", "lldp || cdp || stp"),
        ("Diffusion et multidiffusion", "eth.dst == ff:ff:ff:ff:ff:ff || mdns || ssdp || nbns || igmp"),
        ("IPv6", "ipv6"),
        ("Grands paquets (plus de 1 000 octets)", "frame.len > 1000"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.isRunning { statusRow } else { controls }
            if let error = model.error { ToolNotice(tone: .critical, message: error) }
            if let notice = model.notice { ToolNotice(tone: .success, message: notice) }
            if model.phase == .authorizing {
                ToolNotice(tone: .accent, title: "Autorisation demandée par macOS",
                           message: "Saisissez le mot de passe d’un administrateur dans la fenêtre de macOS. tcpdump sera lancé une seule fois, en lecture seule, et s’arrêtera seul après \(Self.durationLabel(model.duration)), \(PacketText.number(model.packetLimit)) paquets ou au clic sur «\u{00A0}Arrêter\u{00A0}».")
            }
            if model.log.isEmpty && model.method != .file {
                if model.isRunning { waiting } else { accessNotice }
            } else {
                if !model.isRunning { summaryBar }
                paneBar
                switch model.pane {
                case .packets: packetsPane
                case .flow: flowPane
                case .statistics: statisticsPane
                }
            }
            limitsFootnote
        }
        .task { await model.prepare(active: state.activeInterface) }
    }

    // MARK: Réglages

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            ToolAdaptiveRow {
                ToolLabeledField(label: "Interface") {
                    Picker("", selection: $model.interfaceName) {
                        if model.interfaces.isEmpty { Text("aucune interface").tag("") }
                        ForEach(model.interfaces, id: \.name) { iface in Text(iface.linkSummary).tag(iface.name) }
                    }
                    .labelsHidden()
                    .controlSize(.large)
                    .frame(minWidth: 150)
                    .fixedSize(horizontal: true, vertical: false)
                }
                ToolLabeledField(label: "Filtre de capture (syntaxe tcpdump)") {
                    HStack(spacing: 6) {
                        ToolTextField(placeholder: "ex. host 10.182.122.1 and not port 22", text: $model.captureFilter, height: 30) {
                            model.start(store: store)
                        }
                        .frame(minWidth: 210)
                        presetMenu
                    }
                }
                startButton
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 14) {
                    limitPickers
                    Spacer(minLength: 8)
                    fileButtons
                }
                VStack(alignment: .leading, spacing: 8) {
                    limitPickers
                    fileButtons
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 14) { sizePickers }.fixedSize()
                    HStack(spacing: 14) {
                        promiscuousToggle
                        fileButtons
                    }
                    .fixedSize()
                }
                VStack(alignment: .leading, spacing: 8) {
                    VStack(alignment: .leading, spacing: 6) { limitPickerItems }
                    fileButtons
                }
            }
        }
    }

    private var presetMenu: some View {
        Menu {
            ForEach(CapturePreset.allCases) { preset in
                Button {
                    model.applyPreset(preset, gateway: state.activeInterface?.gateway)
                } label: {
                    Text(preset.label) + Text(preset == .all ? "" : "  \(preset.text(host: "…", port: 443))")
                }
            }
        } label: {
            Label("Préréglages", systemImage: "line.3.horizontal.decrease.circle")
        }
        .menuStyle(.button)
        .controlSize(.large)
        .fixedSize()
        .help("Filtres simples\u{00A0}: hôte, port, ARP, DNS, DHCP, ICMP, LLDP/CDP")
    }

    private var startButton: some View {
        Button { model.start(store: store) } label: {
            Label(model.bpfAvailable || model.method == .demo ? "Démarrer la capture" : "Capturer (administrateur)",
                  systemImage: model.bpfAvailable || model.method == .demo ? "record.circle" : "lock.open")
        }
        .buttonStyle(.primary)
        .fixedSize()
        .disabled(model.interfaceName.isEmpty)
        .help(model.bpfAvailable ? "Lecture directe de /dev/bpf (ChmodBPF)" : "tcpdump lancé une fois avec votre autorisation, en lecture seule")
    }

    private var limitPickers: some View {
        HStack(spacing: 14) { limitPickerItems }
            .fixedSize()
    }

    @ViewBuilder private var limitPickerItems: some View {
        sizePickers
        promiscuousToggle
    }

    @ViewBuilder private var sizePickers: some View {
        inlinePicker("Durée", selection: $model.duration, values: ToolPacketCaptureModel.durations, label: Self.durationLabel)
        inlinePicker("Paquets", selection: $model.packetLimit, values: ToolPacketCaptureModel.packetLimits) { PacketText.number($0) }
        inlinePicker("Taille", selection: $model.sizeLimit, values: ToolPacketCaptureModel.sizeLimits) { "\($0)\u{00A0}Mo" }
    }

    private var promiscuousToggle: some View {
        ToolCheckbox(label: "Mode promiscuité", isOn: $model.promiscuous)
            .fixedSize()
            .help("Recevoir aussi les trames destinées à d’autres appareils (utile sur un port miroir\u{00A0}; sans effet sur la plupart des réseaux Wi-Fi)")
    }

    private func inlinePicker(_ title: String, selection: Binding<Int>, values: [Int], label: @escaping (Int) -> String) -> some View {
        HStack(spacing: 6) {
            Text(title).font(Theme.small).foregroundStyle(Theme.textSecondary)
            Picker("", selection: selection) {
                ForEach(values, id: \.self) { Text(label($0)).tag($0) }
            }
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
        }
        .fixedSize()
    }

    private var fileButtons: some View {
        HStack(spacing: 8) {
            Button { model.openFile() } label: { Label("Ouvrir…", systemImage: "folder") }
                .buttonStyle(.secondary)
                .controlSize(.small)
                .help("Ouvrir un fichier .pcap ou .pcapng (Wireshark, tcpdump)")
            Menu {
                Button("Tous les paquets (\(PacketText.number(model.log.count)))") { model.save(displayedOnly: false) }
                Button("Paquets affichés (\(PacketText.number(model.rows.count)))") { model.save(displayedOnly: true) }
                    .disabled(model.rows.isEmpty)
            } label: {
                Label("Enregistrer en .pcap", systemImage: "square.and.arrow.down")
            }
            .menuStyle(.button)
            .controlSize(.small)
            .fixedSize()
            .disabled(model.log.isEmpty)
            .help("Format pcap classique, ouvrable dans Wireshark")
        }
        .fixedSize()
    }

    static func durationLabel(_ seconds: Int) -> String {
        seconds < 60 ? "\(seconds)\u{00A0}s" : "\(seconds / 60)\u{00A0}min"
    }

    // MARK: Déroulement

    private var statusRow: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 10) {
                    Circle().fill(model.phase == .capturing ? Theme.criticalBadge : Theme.warningDot).frame(width: 10, height: 10)
                    Text(model.phase == .capturing ? "Capture en cours sur \(interfaceLabel)"
                         : model.phase == .preparing ? "Préparation du filtre…" : "En attente de l’autorisation pour \(interfaceLabel)")
                        .font(Theme.bodySemibold)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    if model.phase == .capturing {
                        Text(progressText(now: context.date))
                            .font(Theme.mono(12, weight: .medium))
                            .foregroundStyle(Theme.textSecondary)
                            .monospacedDigit()
                            .lineLimit(1)
                    }
                    Button("Arrêter") { model.stop() }
                        .buttonStyle(.secondary)
                }
                Text(filterDescription + methodSuffix)
                    .font(Theme.small).foregroundStyle(Theme.textSecondary)
                    .padding(.leading, 20)
                    .lineLimit(1)
            }
        }
    }

    private func progressText(now: Date) -> String {
        let elapsed = Int(now.timeIntervalSince(model.startedAt ?? now))
        return "\(PacketText.number(model.log.count)) paquets · \(PacketText.bytes(model.log.byteCount)) · \(Self.clock(elapsed)) / \(Self.clock(model.duration))"
    }

    static func clock(_ seconds: Int) -> String { String(format: "%02d:%02d", seconds / 60, seconds % 60) }

    private var filterDescription: String {
        let filter = CaptureFilterCompiler.normalized(model.captureFilter)
        return filter.isEmpty ? "Tout le trafic" : "Filtre «\u{00A0}\(filter)\u{00A0}»"
    }

    private var methodSuffix: String {
        switch model.method {
        case .bpf: return " · accès BPF direct" + (model.filterSource == .tcpdump ? " · filtre compilé par tcpdump" : model.filterSource == .handWritten ? " · préréglage" : "")
        case .privileged: return " · tcpdump (administrateur)"
        case .demo: return " · démonstration"
        default: return ""
        }
    }

    private var interfaceLabel: String {
        guard let iface = model.selectedInterface else { return model.interfaceName }
        return "\(iface.name) · \(iface.kind.label)"
    }

    private var waiting: some View {
        HStack(spacing: 12) {
            ProgressView().controlSize(.small)
            Text(model.phase == .capturing ? "En attente des premiers paquets…" : "Préparation…")
                .font(Theme.body).foregroundStyle(Theme.textSecondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.panelRadius).fill(Theme.panelMuted))
        .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
    }

    private var accessNotice: some View {
        ToolNotice(tone: .accent, title: model.bpfAvailable ? "Accès direct aux paquets (BPF)" : "Droits d’administrateur nécessaires",
                   message: model.bpfAvailable
                   ? "Ce Mac permet déjà la lecture de /dev/bpf (ChmodBPF de Wireshark)\u{00A0}: la capture démarre sans mot de passe. Rien n’est envoyé sur le réseau\u{00A0}; vous pouvez aussi ouvrir un fichier .pcap."
                   : "Lire les paquets demande /dev/bpf, réservé à root. NetScope lance tcpdump une seule fois avec votre autorisation (fenêtre de macOS), en lecture seule, avec une durée et un nombre de paquets bornés. Rien n’est envoyé sur le réseau\u{00A0}; vous pouvez aussi ouvrir un fichier .pcap.")
    }

    // MARK: Résumé et onglets

    private var summaryBar: some View {
        let stats = model.statistics(displayedOnly: false)
        let seconds = model.log.duration
        let icon = Image(systemName: model.method == .file ? "doc" : "checkmark.circle")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(model.method == .file ? Theme.textSecondary : Theme.success)
        let title = Text(summaryTitle).font(Theme.bodySemibold).lineLimit(1)
        let figures = Text("\(PacketText.number(model.log.count)) paquets · \(PacketText.seconds(seconds, decimals: 1))\u{00A0}s · \(PacketText.bytes(model.log.byteCount))")
            .font(Theme.mono(12)).foregroundStyle(Theme.textSecondary)
            .lineLimit(1)
        let chips = HStack(spacing: 6) {
            if stats.count(.retransmission) > 0 {
                Chip(text: "\(stats.count(.retransmission)) retransmission\(stats.count(.retransmission) > 1 ? "s" : "")", tone: .warning)
            }
            if stats.count(.reset) > 0 { Chip(text: "\(stats.count(.reset)) RST", tone: .critical) }
        }
        // Une ligne quand la place suffit ; sinon le titre, puis les chiffres et les alertes dessous.
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                icon
                title.fixedSize()
                figures.fixedSize()
                Spacer(minLength: 6)
                chips
            }
            .frame(height: 34)
            HStack(alignment: .top, spacing: 10) {
                icon.padding(.top, 2)
                VStack(alignment: .leading, spacing: 4) {
                    title
                    HStack(spacing: 8) {
                        figures
                        chips
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 8)
        }
        .padding(.horizontal, 12)
        .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.panelMuted))
        .overlay(RoundedRectangle(cornerRadius: Theme.buttonRadius).strokeBorder(Theme.border))
    }

    private var summaryTitle: String {
        switch model.method {
        case .file: return model.sourceName ?? "Fichier"
        case .demo: return "Capture sur \(model.sourceName ?? model.interfaceName) (démonstration)"
        default:
            return "Capture sur \(model.sourceName ?? model.interfaceName)" + (model.stopReason.map { " · \($0)" } ?? "")
        }
    }

    private var paneBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                panePicker
                if model.pane == .packets { displayFilterField.frame(minWidth: 220) } else { Spacer(minLength: 0) }
            }
            VStack(alignment: .leading, spacing: 8) {
                panePicker
                if model.pane == .packets { displayFilterField }
            }
        }
    }

    private var panePicker: some View {
        Picker("", selection: Binding(get: { model.pane }, set: { pane in
            if pane == .flow, model.stream == nil { model.followSelected() } else { model.pane = pane }
        })) {
            ForEach(ToolPacketCaptureModel.Pane.allCases) { pane in Text(pane.label).tag(pane) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }

    private var displayFilterField: some View {
        HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal.decrease")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.textTertiary)
            ToolTextField(placeholder: "Filtre d’affichage\u{00A0}: ex. dns || tcp.port == 443", text: $model.displayFilter,
                          invalid: model.displayFilterError != nil, height: 26)
                .help(model.displayFilterError ?? "Protocoles, ip.addr, port, tcp.flags.syn, tls.sni contains…, avec && (et), || (ou), ! (non)")
            Menu {
                ForEach(Self.quickFilters, id: \.1) { item in
                    Button(item.0) { model.displayFilter = item.1 }
                }
                Divider()
                Button("Effacer le filtre") { model.displayFilter = "" }.disabled(model.displayFilter.isEmpty)
            } label: {
                Image(systemName: "chevron.down.circle")
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .controlSize(.small)
            .fixedSize()
            .help("Filtres d’affichage courants")
            Text("\(PacketText.number(model.rows.count))\u{00A0}/\u{00A0}\(PacketText.number(model.log.count))")
                .font(Theme.mono(11)).foregroundStyle(Theme.textSecondary)
                .fixedSize()
                .help("Paquets affichés / capturés")
            ToolColumnsMenu(model: packetTable)
        }
    }

    // MARK: Paquets

    private var packetsPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let message = model.displayFilterError {
                Text(message).font(Theme.small).foregroundStyle(Theme.critical)
            }
            PacketListTable(rows: model.rows, model: model, table: packetTable)
            if let packet = model.selectedPacket {
                detailHeader(packet)
                detail(packet)
            } else {
                Text("Choisissez un paquet pour voir son détail par couche et ses octets.")
                    .font(Theme.small).foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private func detailHeader(_ packet: CapturedPacket) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                frameTitle(packet)
                Spacer(minLength: 8)
                detailButtons
            }
            VStack(alignment: .leading, spacing: 6) {
                frameTitle(packet)
                detailButtons
            }
        }
    }

    private func frameTitle(_ packet: CapturedPacket) -> some View {
        var text = "Trame \(packet.id)\u{00A0}: \(PacketText.octets(packet.length)) sur le fil"
        if packet.record.data.count < packet.length { text += ", \(PacketText.octets(packet.record.data.count)) capturés" }
        text += " · \(PacketListTable.clock(packet.date))"
        if !packet.analysis.isEmpty { text += " · " + packet.analysis.map(\.label).sorted().joined(separator: ", ") }
        return VStack(alignment: .leading, spacing: 2) {
            Text(text).font(Theme.bodySemibold).lineLimit(1).truncationMode(.tail)
            if let field = model.selectedField.flatMap({ packet.decoded.field($0) }) {
                Text("\(field.name) · octets \(field.offset) à \(field.offset + max(field.length, 1) - 1) (\(PacketText.octets(field.length)))")
                    .font(Theme.small).foregroundStyle(Theme.textSecondary).lineLimit(1)
            } else if !packet.decoded.problems.isEmpty {
                Text(packet.decoded.problems.joined(separator: " · ")).font(Theme.small).foregroundStyle(Theme.warning).lineLimit(1)
            }
        }
    }

    private var detailButtons: some View {
        HStack(spacing: 8) {
            Button { model.followSelected() } label: { Label("Suivre le flux", systemImage: "arrow.left.arrow.right") }
                .buttonStyle(.secondary)
                .controlSize(.small)
                .disabled(!model.canFollow)
                .help("Données de la conversation TCP ou UDP, remises dans l’ordre")
            Menu {
                Button("Copier le résumé") { if let packet = model.selectedPacket { ToolActions.copy(packet.summary) } }
                Button("Copier le détail") { if let packet = model.selectedPacket { ToolActions.copy(Self.treeText(packet.decoded)) } }
                Button("Copier les octets (hexadécimal)") {
                    if let packet = model.selectedPacket { ToolActions.copy(PacketFlowView.hexDump(packet.record.data)) }
                }
                if let field = model.selectedField.flatMap({ model.selectedPacket?.decoded.field($0) }) {
                    Divider()
                    Button("Copier « \(field.name) »") { ToolActions.copy(field.value) }
                    Button("Filtrer sur cette valeur") { applyFieldFilter(field) }
                }
            } label: {
                Label("Copier", systemImage: "doc.on.doc")
            }
            .menuStyle(.button)
            .controlSize(.small)
            .fixedSize()
        }
        .fixedSize()
    }

    /// Filtre d'affichage tiré d'un champ connu (adresse, port, nom).
    private func applyFieldFilter(_ field: PacketField) {
        let value = field.value.split(separator: " ").first.map(String.init) ?? field.value
        switch field.name {
        case "Adresse source", "Adresse de destination", "IP de l’émetteur", "IP de la cible": model.displayFilter = "ip.addr == \(value)"
        case "Port source", "Port de destination": model.displayFilter = "port \(value)"
        case "Nom du serveur (SNI)": model.displayFilter = "tls.sni == \"\(field.value)\""
        case "Destination", "Source", "MAC de l’émetteur", "MAC de la cible": model.displayFilter = "eth.addr == \(value)"
        default: model.displayFilter = "info contains \"\(value)\""
        }
    }

    static func treeText(_ packet: DecodedPacket) -> String {
        var lines: [String] = []
        func visit(_ field: PacketField, depth: Int) {
            lines.append(String(repeating: "    ", count: depth) + field.text)
            field.children.forEach { visit($0, depth: depth + 1) }
        }
        packet.roots.forEach { visit($0, depth: 0) }
        return lines.joined(separator: "\n")
    }

    private func detail(_ packet: CapturedPacket) -> some View {
        let field = model.selectedField.flatMap { packet.decoded.field($0) }
        let layer = field.flatMap { selected in packet.decoded.layers.first { $0.node.find(selected.id) != nil }?.node }
        func hex(_ perRow: Int) -> some View {
            PacketHexView(bytes: packet.record.data, highlight: field.map(\.range), layer: layer.map(\.range), bytesPerRow: perRow) { offset in
                model.selectByte(offset)
            }
        }
        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 10) {
                PacketTreeView(packet: packet, model: model).frame(minWidth: 300)
                hex(16)
            }
            VStack(alignment: .leading, spacing: 10) {
                PacketTreeView(packet: packet, model: model)
                hex(16)
            }
            VStack(alignment: .leading, spacing: 10) {
                PacketTreeView(packet: packet, model: model)
                hex(8)
            }
        }
    }

    // MARK: Flux

    @ViewBuilder private var flowPane: some View {
        if let stream = model.stream {
            let isTLS = stream.packetNumbers.contains { model.log.packet($0)?.decoded.contains(.tls) ?? false }
            PacketFlowView(stream: stream, isTLS: isTLS, model: model)
        } else {
            ToolNotice(tone: .neutral, message: "Choisissez un paquet TCP ou UDP dans la liste, puis «\u{00A0}Suivre le flux\u{00A0}»\u{00A0}: ses données sont remises dans l’ordre, sans les retransmissions.")
        }
    }

    // MARK: Statistiques

    private var statisticsPane: some View {
        let stats = model.statistics(displayedOnly: true)
        let rate = stats.duration > 0 ? Double(stats.byteCount * 8) / stats.duration : 0
        return VStack(alignment: .leading, spacing: 14) {
            Text(model.displayFilter.isEmpty ? "Toute la capture" : "Paquets affichés par le filtre «\u{00A0}\(model.displayFilter)\u{00A0}»")
                .font(Theme.small).foregroundStyle(Theme.textSecondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 8)], spacing: 8) {
                ToolStatTile(label: "Paquets", value: PacketText.number(stats.packetCount))
                ToolStatTile(label: "Octets", value: PacketText.bytes(stats.byteCount))
                ToolStatTile(label: "Durée", value: PacketText.seconds(stats.duration, decimals: 1) + "\u{00A0}s")
                ToolStatTile(label: "Débit moyen", value: Self.bitRate(rate))
                ToolStatTile(label: "Retransmissions", value: "\(stats.count(.retransmission))",
                             valueColor: stats.count(.retransmission) > 0 ? Theme.warning : Theme.text)
                ToolStatTile(label: "Hors ordre", value: "\(stats.count(.outOfOrder))",
                             valueColor: stats.count(.outOfOrder) > 0 ? Theme.warning : Theme.text)
                ToolStatTile(label: "ACK en double", value: "\(stats.count(.duplicateAck))",
                             valueColor: stats.count(.duplicateAck) > 0 ? Theme.warning : Theme.text)
                ToolStatTile(label: "Réinitialisations (RST)", value: "\(stats.count(.reset))",
                             valueColor: stats.count(.reset) > 0 ? Theme.critical : Theme.text)
            }
            section("Protocoles · \(stats.protocols.count)", table: protocolTable) {
                ProtocolStatsTable(rows: stats.protocols.map { ProtocolStatRow(stat: $0, share: stats.packetCount > 0 ? Double($0.packets) / Double(stats.packetCount) : 0) },
                                   table: protocolTable)
            }
            section("Conversations · \(stats.conversations.count)", table: conversationTable) {
                ConversationStatsTable(rows: stats.conversations.map(ConversationStatRow.init), table: conversationTable)
            }
            section("Plus gros émetteurs · \(stats.talkers.count)", table: talkerTable) {
                TalkerStatsTable(rows: stats.talkers.map(TalkerStatRow.init), table: talkerTable)
            }
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

    /// « 12,4 kbit/s », « 3,2 Mbit/s ».
    static func bitRate(_ bits: Double) -> String {
        let units = ["bit/s", "kbit/s", "Mbit/s", "Gbit/s"]
        var value = bits
        var unit = 0
        while value >= 1000, unit < units.count - 1 { value /= 1000; unit += 1 }
        return String(format: unit == 0 ? "%.0f" : "%.1f", value).replacingOccurrences(of: ".", with: ",") + "\u{00A0}" + units[unit]
    }

    // MARK: Limites

    private var limitsFootnote: some View {
        Text("Limites\u{00A0}: pas de déchiffrement TLS (seuls le Client Hello, le SNI et le Server Hello sont lisibles)\u{00A0}; décodeurs de base (Ethernet, 802.1Q, ARP, IPv4/IPv6, ICMP, TCP, UDP, DNS, mDNS, NetBIOS, DHCP, HTTP, TLS, LLDP/CDP, STP), loin des milliers de Wireshark\u{00A0}; HTTP et TLS sont lus segment par segment, sans réassemblage. Pour aller plus loin, enregistrez en .pcap et ouvrez le fichier dans Wireshark.")
            .font(Theme.caption)
            .foregroundStyle(Theme.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
