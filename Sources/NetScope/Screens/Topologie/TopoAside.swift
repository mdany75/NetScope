import NetScopeCore
import SwiftUI

/// Colonne de droite de la carte : détail du nœud choisi (ou vue d'ensemble) et problèmes repérés.
struct TopoAside: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var model = InvModel.shared
    /// Emplacements relevés (note 18) : un ancien relevé est signalé comme dans le Scanner.
    @ObservedObject private var switches = SwitchStore.shared

    let graph: TopoGraph
    @Binding var selectedID: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let node = selectedID.flatMap({ graph.node($0) }) {
                    detail(node)
                } else {
                    overview
                }
                problems
            }
        }
    }

    // MARK: Nœud choisi

    private func detail(_ node: TopoNode) -> some View {
        let colors = TopoStyle.colors(kind: node.kind, type: node.deviceType)
        let devices = node.deviceIDs.compactMap { state.device(withID: $0) }
        let single = devices.count == 1 && node.kind != .groupe ? devices.first : nil

        return Panel(padding: 16) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: TopoStyle.symbol(kind: node.kind, type: node.deviceType))
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(colors.fg)
                        .frame(width: 40, height: 40)
                        .background(RoundedRectangle(cornerRadius: 8).fill(colors.bg))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(node.title).font(Theme.panelTitle).lineLimit(2)
                        Text(node.subtitle).font(Theme.mono(12)).foregroundStyle(Theme.neutralText)
                        HStack(spacing: 6) {
                            statusPill(node)
                            InvPill(text: node.kind == .groupe ? "Groupe" : (node.deviceType?.label ?? node.kind.label),
                                    foreground: Theme.neutralText, background: Theme.neutralSoft)
                        }
                    }
                    Spacer(minLength: 0)
                    Button { selectedID = nil } label: {
                        Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .help("Effacer la sélection")
                }

                if node.status == .critique {
                    Text(conflictText(devices))
                        .font(Theme.small).foregroundStyle(Color(light: 0x991B1B, dark: 0xED9797))
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.criticalSoft))
                }

                if let device = single {
                    VStack(spacing: 0) {
                        KeyValueRow(key: "MAC", value: device.mac?.formatted(.upperColon) ?? "—", mono: true, keyWidth: 92)
                        KeyValueRow(key: "Fabricant", value: device.vendorLabel, keyWidth: 92)
                        KeyValueRow(key: "VLAN", value: device.vlan.map(String.init) ?? "—", keyWidth: 92)
                        KeyValueRow(key: "Emplacement", value: device.switchLocation.map { state.locationStatus(device).isCurrent ? $0 : "\($0) (ancien relevé)" } ?? "Port inconnu",
                                    mono: device.switchLocation != nil, keyWidth: 92)
                            .help(device.switchLocation == nil ? "" : state.locationStatus(device).explanation ?? "")
                        KeyValueRow(key: "Découverte", value: "Scan (ARP, ping)" + (device.openPorts.isEmpty ? "" : ", ports TCP"), keyWidth: 92)
                        KeyValueRow(key: "Vu", value: device.isOnline ? "Maintenant" : InvFormat.relative(device.lastSeen), keyWidth: 92)
                    }
                } else if node.kind == .internet {
                    Text("Au-delà de la passerelle : le lien vers le fournisseur d’accès n’est pas sondé par le scan local.")
                        .font(Theme.small).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                } else if node.isInferred {
                    Text(node.id == "sw:?"
                         ? "Regroupe les appareils dont le port de switch n’a pas été relevé. Interrogez les switchs par SNMP pour les placer."
                         : "Switch connu seulement par son nom, relevé sur les appareils qui y sont branchés ; son adresse n’a pas été vue par le scan.")
                        .font(Theme.small).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                }

                if node.kind == .groupe {
                    members(devices)
                }

                let children = graph.children(of: node.id)
                if !children.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        SectionHeader("Branchés en dessous")
                        ForEach(children) { child in
                            Button { selectedID = child.id } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: TopoStyle.symbol(kind: child.kind, type: child.deviceType))
                                        .font(.system(size: 11)).foregroundStyle(Theme.neutralText).frame(width: 16)
                                    Text(child.title).font(Theme.small).lineLimit(1)
                                    Spacer(minLength: 4)
                                    Text(child.uplinkLabel ?? "—").font(Theme.mono(11)).foregroundStyle(Theme.textSecondary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                HStack(spacing: 8) {
                    if let device = single {
                        Button { state.showDevice(device.id) } label: { Label("Ouvrir la fiche", systemImage: "doc.text") }
                            .buttonStyle(.primary)
                    }
                    if node.kind == .switch || node.kind == .pointAcces || node.kind == .passerelle {
                        Button { state.open(.switchs) } label: { Label("Voir les ports", systemImage: Screen.switchs.symbol) }
                            .buttonStyle(.secondary)
                    }
                    if node.kind == .groupe, let first = devices.first {
                        Button {
                            model.selectedKey = model.store.record(forIP: first.ip)?.key
                            state.open(.inventaire)
                        } label: { Label("Inventaire", systemImage: Screen.inventaire.symbol) }
                            .buttonStyle(.secondary)
                    }
                }
            }
        }
    }

    private func statusPill(_ node: TopoNode) -> some View {
        switch node.status {
        case .ok:
            return InvPill(text: node.kind == .groupe ? "\(node.onlineCount) en ligne" : "En ligne",
                           foreground: Theme.success, background: Theme.successSoft)
        case .horsLigne:
            return InvPill(text: "Hors ligne", foreground: Theme.textSecondary, background: Theme.neutralSoft)
        case .critique:
            return InvPill(text: "Conflit IP", foreground: Theme.critical, background: Theme.criticalSoft)
        }
    }

    private func conflictText(_ devices: [Device]) -> String {
        let ips = devices.map(\.ip).filter { model.store.conflictIPs.contains($0) }
        let text = ips.map { ip -> String in
            let macs = model.store.records.values.filter { $0.ip == ip && $0.isOnline }.compactMap { $0.mac?.formatted(.upperColon) }
            return "\(ip) : " + (macs.isEmpty ? "plusieurs MAC" : macs.joined(separator: " et "))
        }
        return "Conflit IP. " + text.joined(separator: " · ") + " répondent."
    }

    private func members(_ devices: [Device]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: "Membres", subtitle: "\(devices.count) appareil\(devices.count > 1 ? "s" : "")") { EmptyView() }
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 0) {
                GridRow {
                    ForEach(["Appareil", "IP", "Port"], id: \.self) { title in
                        Text(title.uppercased()).font(Theme.captionSemibold).foregroundStyle(Theme.textSecondary)
                            .frame(height: 24, alignment: .leading)
                    }
                }
                ForEach(devices.prefix(10)) { device in
                    GridRow {
                        HStack(spacing: 5) {
                            StatusDot(online: device.isOnline, size: 6)
                            Text(device.displayName).font(Theme.small).lineLimit(1)
                        }
                        Text(device.ip.description).font(Theme.mono(11))
                        Text(device.switchPort ?? "—").font(Theme.mono(11)).foregroundStyle(Theme.neutralText)
                    }
                    .frame(height: 26)
                    .contentShape(Rectangle())
                    .onTapGesture { state.showDevice(device.id) }
                }
            }
            if devices.count > 10 {
                Text("et \(devices.count - 10) autres").font(Theme.small).foregroundStyle(Theme.textSecondary)
            }
        }
    }

    // MARK: Vue d'ensemble

    private var overview: some View {
        let networks = Set(state.devices.map { $0.ip.value & 0xFFFF_FF00 }).sorted()
            .map { Subnet(address: IPv4Address($0), prefix: 24).description }
        let vlans = Set(state.devices.compactMap(\.vlan)).sorted().map(String.init)
        return Panel(padding: 16) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Vue d’ensemble").font(Theme.panelTitle)
                Text("Cliquez sur un nœud de la carte pour afficher son détail, ses membres et ce qui est branché en dessous.")
                    .font(Theme.small).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                VStack(spacing: 0) {
                    KeyValueRow(key: "Nœuds affichés", value: "\(graph.nodes.count)", keyWidth: 110)
                    KeyValueRow(key: "Liens affichés", value: "\(graph.links.count)", keyWidth: 110)
                    KeyValueRow(key: "Sous-réseaux", value: networks.isEmpty ? "—" : networks.joined(separator: "\n"), mono: true, keyWidth: 110)
                    KeyValueRow(key: "VLAN", value: vlans.isEmpty ? "—" : vlans.joined(separator: " · "), keyWidth: 110)
                }
            }
        }
    }

    // MARK: Problèmes

    private var problems: some View {
        // Types affichés (choisis à la main compris), comme les nœuds de la carte (note 20).
        let devices = model.withManualTypes(state.devices)
        let conflicts = model.store.conflictIPs.filter { ip in devices.contains { $0.ip == ip } }.sorted()
        let offlineInfra = devices.filter { !$0.isOnline && [.switch, .pointAcces, .routeur].contains($0.deviceType) }
        let unplaced = graph.node("sw:?").map { graph.children(of: $0.id).flatMap(\.deviceIDs).count } ?? 0

        return Panel(padding: 16) {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader("Problèmes sur la carte")
                if conflicts.isEmpty && offlineInfra.isEmpty && unplaced == 0 {
                    Text("Aucun problème repéré par le dernier scan.").font(Theme.small).foregroundStyle(Theme.textSecondary)
                }
                ForEach(conflicts, id: \.self) { ip in
                    problem(.critical, "Conflit IP · \(ip)", "Plusieurs MAC répondent à cette adresse") {
                        selectedID = graph.nodes.first { node in node.deviceIDs.contains(ip.description) }?.id
                    }
                }
                ForEach(offlineInfra) { device in
                    problem(.warning, "Hors ligne · \(device.displayName)", "\(device.deviceType.label) · \(device.ip)") {
                        selectedID = "dev:" + device.id
                    }
                }
                if unplaced > 0 {
                    problem(.neutral, "\(unplaced) appareil\(unplaced > 1 ? "s" : "") sans port de switch connu",
                            "Placés sous « Switchs » : le lien exact demande SNMP/LLDP") {
                        selectedID = "sw:?"
                    }
                }
                Button { state.open(.analyse) } label: {
                    HStack {
                        Text("Ouvrir l’analyse et les alertes").font(.system(size: 12, weight: .semibold))
                        Spacer()
                        Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundStyle(Theme.accentStrong)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }
        }
    }

    private func problem(_ tone: Tone, _ title: String, _ detail: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                StatusDot(tone: tone, size: 8).padding(.top, 4)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text)
                    Text(detail).font(Theme.caption).foregroundStyle(Theme.textSecondary)
                }
                Spacer(minLength: 0)
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.panelMuted))
            .overlay(RoundedRectangle(cornerRadius: Theme.buttonRadius).strokeBorder(Theme.border))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
