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
    /// Appareils du dessin (types choisis à la main compris) : ceux d'UN seul site.
    let devices: [Device]
    /// Site du dessin, et vrai s'il s'agit du site actif (appareils du Scanner : fiche complète, relevés).
    var siteKey: String
    var isActiveSite = true
    /// Adresses en conflit dans l'inventaire de ce site.
    var conflictIPs: Set<IPv4Address> = []
    /// Note 32 : recherche de la carte (fiche du résultat en tête du détail).
    var search: TopoSearchContext?
    var searchActions: TopoSearchActions?
    /// Note 78 : filtre VLAN de la carte (rappelé dans la vue d'ensemble) et nom des VLAN du site.
    var vlanFilter: TopoVLANFilter = .all
    var vlanName: (Int) -> String? = { _ in nil }

    private func device(_ id: String) -> Device? { devices.first { $0.id == id } }

    private func open(_ device: Device) {
        if isActiveSite {
            state.showDevice(device.id)
        } else if let key = model.inventory(for: siteKey).record(forIP: device.ip)?.key {
            // Autre site : sa fiche d'inventaire (le Scanner n'a que les appareils du site actif).
            model.selectedSite = siteKey
            model.selectedKey = key
            state.open(.inventaire)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let search, let searchActions {
                    TopoSearchPanel(search: search, graph: graph, devices: devices, actions: searchActions,
                                    open: open, select: { selectedID = $0 }, selectedID: selectedID)
                }
                if let node = selectedID.flatMap({ graph.node($0) }) {
                    // Un appareil seul trouvé par la recherche : sa fiche est déjà en tête.
                    if !(search?.current?.nodeID == node.id && node.kind == .appareil) {
                        detail(node)
                    }
                } else if search == nil {
                    overview
                }
                problems
            }
        }
    }

    // MARK: Nœud choisi

    private func detail(_ node: TopoNode) -> some View {
        let colors = TopoStyle.colors(kind: node.kind, type: node.deviceType)
        let devices = node.deviceIDs.compactMap { device($0) }
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
                        KeyValueRow(key: "Emplacement", value: device.switchLocation.map { !isActiveSite || state.locationStatus(device).isCurrent ? $0 : "\($0) (ancien relevé)" } ?? "Port inconnu",
                                    mono: device.switchLocation != nil, keyWidth: 92)
                            .help(device.switchLocation == nil || !isActiveSite ? "" : state.locationStatus(device).explanation ?? "")
                        KeyValueRow(key: "Découverte", value: "Scan (ARP, ping)" + (device.openPorts.isEmpty ? "" : ", ports TCP"), keyWidth: 92)
                        KeyValueRow(key: "Vu", value: InvFormat.seen(device.lastSeen, online: device.isOnline), keyWidth: 92)
                    }
                } else if node.kind == .internet {
                    Text("Au-delà de la passerelle : le lien vers le fournisseur d’accès n’est pas sondé par le scan local.")
                        .font(Theme.small).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                } else if node.isInferred {
                    Text(node.id == "sw:?"
                         ? "Regroupe les appareils dont le port de switch n’a pas été relevé. Interrogez les switchs par SNMP pour les placer."
                         : node.note ?? "Switch connu seulement par son nom, relevé sur les appareils qui y sont branchés ; son adresse n’a pas été vue par le scan.")
                        .font(Theme.small).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                }

                let lldp = graph.infraLinks(of: node.id)
                if !lldp.isEmpty {
                    lldpLinks(node, lldp)
                }

                if node.kind == .groupe {
                    members(devices,highlighted: search?.current.flatMap { $0.nodeID == node.id ? $0.deviceID : nil })
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

                // Note 31 : le groupe ou la branche (le nœud et tout ce qui est branché dessous) vers
                // l'Inventaire ou le Scanner, filtrés sur exactement ces appareils, dans le site dessiné.
                let group = graph.navGroup(node.id, devices: self.devices, siteKey: siteKey)
                InvFlowLayout(spacing: 8) {
                    if let device = single {
                        Button { open(device) } label: { Label("Ouvrir la fiche", systemImage: "doc.text") }
                            .buttonStyle(.primary)
                    }
                    if node.kind == .switch || node.kind == .pointAcces || node.kind == .passerelle {
                        Button {
                            if let object = TopoNav.object(node, graph: graph, devices: self.devices, siteKey: siteKey),
                               case .switchUnit = object {
                                state.perform(object)
                            } else {
                                state.open(.switchs)
                            }
                        } label: { Label("Voir les ports", systemImage: Screen.switchs.symbol) }
                            .buttonStyle(.secondary)
                    }
                    if let group {
                        let inventory = Button { state.navigate(NavResolver.groupDestination(group, module: .inventaire)) } label: {
                            Label("Inventaire", systemImage: Screen.inventaire.symbol)
                        }
                        Group {
                            if node.kind == .groupe { inventory.buttonStyle(.primary) } else { inventory.buttonStyle(.secondary) }
                        }
                        .help("Ouvrir l’Inventaire filtré sur \(group.members.count == 1 ? "cet appareil" : "ces \(group.members.count) appareils") («\u{00A0}\(group.filterLabel)\u{00A0}»)")
                        if isActiveSite {
                            Button { state.navigate(NavResolver.groupDestination(group, module: .scanner)) } label: {
                                Label("Scanner", systemImage: Screen.scanner.symbol)
                            }
                            .buttonStyle(.secondary)
                            .help("Ouvrir le Scanner filtré sur ces appareils")
                        }
                    }
                }
                if node.kind != .internet {
                    Text(doubleClickHelp(node))
                        .font(Theme.caption).foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// Aide du double-clic, d'après ce qu'il ouvre vraiment (TopoNav).
    private func doubleClickHelp(_ node: TopoNode) -> String {
        let what: String
        switch TopoNav.object(node, graph: graph, devices: devices, siteKey: siteKey) {
        case .group?: what = "Inventaire filtré sur ses appareils"
        case .switchUnit?: what = "ses ports dans Switchs et ports"
        case .accessPoint?: what = "la borne dans Wi-Fi › FortiAP"
        default: what = "la fiche"
        }
        return "Double-clic\u{00A0}: \(what)\u{00A0}; clic droit\u{00A0}: «\u{00A0}Ouvrir dans\u{00A0}» les autres modules."
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
        let store = model.inventory(for: siteKey)
        let ips = devices.map(\.ip).filter { store.conflictIPs.contains($0) }
        let text = ips.map { ip -> String in
            let macs = store.records.values.filter { $0.ip == ip && $0.isOnline }.compactMap { $0.mac?.formatted(.upperColon) }
            return "\(ip) : " + (macs.isEmpty ? "plusieurs MAC" : macs.joined(separator: " et "))
        }
        return "Conflit IP. " + text.joined(separator: " · ") + " répondent."
    }

    /// `highlighted` : appareil désigné par la recherche (note 32), marqué et toujours dans la liste.
    private func members(_ devices: [Device], highlighted: String? = nil) -> some View {
        var shown = Array(devices.prefix(10))
        if let highlighted, !shown.contains(where: { $0.id == highlighted }),
           let device = devices.first(where: { $0.id == highlighted }) {
            shown[shown.count - 1] = device
        }
        return membersGrid(devices, shown: shown, highlighted: highlighted)
    }

    private func membersGrid(_ devices: [Device], shown: [Device], highlighted: String?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: "Membres", subtitle: "\(devices.count) appareil\(devices.count > 1 ? "s" : "")") { EmptyView() }
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 0) {
                GridRow {
                    ForEach(["Appareil", "IP", "Port"], id: \.self) { title in
                        Text(title.uppercased()).font(Theme.captionSemibold).foregroundStyle(Theme.textSecondary)
                            .frame(height: 24, alignment: .leading)
                    }
                }
                ForEach(shown) { device in
                    let isFound = device.id == highlighted
                    GridRow {
                        HStack(spacing: 5) {
                            if isFound {
                                Image(systemName: "magnifyingglass").font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(Theme.accentStrong)
                            } else {
                                StatusDot(online: device.isOnline, size: 6)
                            }
                            Text(device.displayName).font(isFound ? .system(size: 12, weight: .semibold) : Theme.small).lineLimit(1)
                        }
                        Text(device.ip.description).font(Theme.mono(11, weight: isFound ? .semibold : .regular))
                        Text(device.switchPort ?? "—").font(Theme.mono(11)).foregroundStyle(Theme.neutralText)
                    }
                    .foregroundStyle(isFound ? Theme.accentStrong : Theme.text)
                    .frame(height: 26)
                    .contentShape(Rectangle())
                    .onTapGesture { open(device) }
                    .help(isFound ? "Appareil trouvé par la recherche\u{00A0}; clic\u{00A0}: ouvrir sa fiche" : "")
                }
            }
            if devices.count > 10 {
                Text("et \(devices.count - 10) autres").font(Theme.small).foregroundStyle(Theme.textSecondary)
            }
        }
    }

    // MARK: Liens LLDP (note 78)

    /// Liens de l'équipement vus par LLDP ou la FortiGate : port local, voisin, port distant ; un
    /// clic choisit le voisin sur la carte.
    private func lldpLinks(_ node: TopoNode, _ links: [TopoInfraLink]) -> some View {
        let sorted = links.sorted { lhs, rhs in
            if lhs.isTree != rhs.isTree { return lhs.isTree }
            return (lhs.port(at: node.id) ?? "") .localizedStandardCompare(rhs.port(at: node.id) ?? "") == .orderedAscending
        }
        return VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: "Liens LLDP", subtitle: "\(links.count) lien\(links.count > 1 ? "s" : "")") { EmptyView() }
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 0) {
                GridRow {
                    ForEach(["Port", "Voisin", "Port distant"], id: \.self) { title in
                        Text(title.uppercased()).font(Theme.captionSemibold).foregroundStyle(Theme.textSecondary)
                            .frame(height: 22, alignment: .leading)
                    }
                }
                ForEach(sorted) { link in
                    let other = link.other(node.id)
                    let neighbor = graph.node(other)
                    GridRow {
                        Text(link.port(at: node.id) ?? "—").font(Theme.mono(11))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(neighbor?.title ?? other).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                            Text(lldpDetail(link)).font(Theme.caption).foregroundStyle(Theme.textSecondary).lineLimit(3)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Text(link.port(at: other) ?? "—").font(Theme.mono(11)).foregroundStyle(Theme.neutralText)
                    }
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                    .onTapGesture { if neighbor != nil { selectedID = other } }
                    .help(link.isTree ? "Clic\u{00A0}: choisir \(neighbor?.title ?? "ce voisin") sur la carte"
                          : "Lien redondant\u{00A0}: deuxième chemin vers \(neighbor?.title ?? "ce voisin"), hors de la hiérarchie de la carte")
                }
            }
        }
    }

    /// « ISL · 10 Gb/s · VLAN 1, 20, 30 · FortiGate », « Redondant · … ».
    private func lldpDetail(_ link: TopoInfraLink) -> String {
        var parts = [link.isTree ? link.kind.shortLabel : "Redondant"]
        if let speed = link.speedLabel { parts.append(speed) }
        if !link.vlans.isEmpty {
            let shown = link.vlans.prefix(5).map(String.init).joined(separator: ", ")
            parts.append("VLAN " + shown + (link.vlans.count > 5 ? "…" : ""))
        }
        if !link.isUp { parts.append("hors service") }
        parts.append(link.sourceLabel)
        return parts.joined(separator: " · ")
    }

    // MARK: Vue d'ensemble

    private var overview: some View {
        let networks = Set(devices.map { $0.ip.value & 0xFFFF_FF00 }).sorted()
            .map { Subnet(address: IPv4Address($0), prefix: 24).description }
        let vlans = Set(devices.compactMap(\.vlan)).sorted().map(String.init)
        return Panel(padding: 16) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Vue d’ensemble").font(Theme.panelTitle)
                Text("Cliquez sur un nœud de la carte pour afficher son détail, ses membres et ce qui est branché en dessous.")
                    .font(Theme.small).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                VStack(spacing: 0) {
                    KeyValueRow(key: "Nœuds affichés", value: "\(graph.nodes.count)", keyWidth: 110)
                    KeyValueRow(key: "Liens affichés", value: "\(graph.drawnLinkCount)", keyWidth: 110)
                    KeyValueRow(key: "Sous-réseaux", value: networks.isEmpty ? "—" : networks.joined(separator: "\n"), mono: true, keyWidth: 110)
                    KeyValueRow(key: "VLAN", value: vlans.isEmpty ? "—" : vlans.joined(separator: " · "), keyWidth: 110)
                    if case .vlan(let vlan) = vlanFilter {
                        KeyValueRow(key: "Filtre", value: "VLAN \(vlan)" + (vlanName(vlan).map { " · \($0)" } ?? ""), keyWidth: 110)
                    } else if vlanFilter == .unknown {
                        KeyValueRow(key: "Filtre", value: "VLAN inconnu", keyWidth: 110)
                    }
                    let lldp = graph.infraLinks
                    if !lldp.isEmpty {
                        let redundant = lldp.filter { !$0.isTree }.count
                        KeyValueRow(key: "Liens LLDP", value: "\(lldp.count)" + (redundant > 0 ? " (\(redundant) redondant\(redundant > 1 ? "s" : ""))" : ""),
                                    keyWidth: 110)
                    }
                }
            }
        }
    }

    // MARK: Problèmes

    private var problems: some View {
        // Types affichés (choisis à la main compris), comme les nœuds de la carte (note 20).
        let conflicts = conflictIPs.filter { ip in devices.contains { $0.ip == ip } }.sorted()
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
                ActionRow {
                    Button("Ouvrir l’historique et les alertes") { state.open(.analyse) }
                        .buttonStyle(.secondary)
                }
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

/// Note 34 : objet d'un nœud de la carte, pour le double-clic et « Ouvrir dans › ».
@MainActor
enum TopoNav {
    static func object(_ node: TopoNode, graph: TopoGraph, devices: [Device], siteKey: String) -> NavObject? {
        let device = node.deviceIDs.first.flatMap { id in devices.first { $0.id == id } }
        switch node.kind {
        case .internet:
            return nil
        case .groupe:
            return graph.navGroup(node.id, devices: devices, siteKey: siteKey).map(NavObject.group)
        case .switch:
            // « Switchs » des ports non découverts : la branche de ces appareils.
            if node.id == "sw:?" { return graph.navGroup(node.id, devices: devices, siteKey: siteKey).map(NavObject.group) }
            return .switchUnit(host: device?.ip.description, name: device?.hostname ?? node.title)
        case .pointAcces:
            if let device, let ap = FortiAPStore.shared.overview.aps.first(where: { $0.ip == device.ip }) {
                return .accessPoint(id: ap.id, name: ap.name, ip: device.ip.description)
            }
            return device.map { .device(NavDeviceRef($0, siteKey: siteKey)) }
        case .passerelle, .appareil:
            return device.map { .device(NavDeviceRef($0, siteKey: siteKey)) }
        }
    }
}
