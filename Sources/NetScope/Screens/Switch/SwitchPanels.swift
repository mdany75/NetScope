import AppKit
import NetScopeCore
import SwiftUI

// Blocs de l'écran Switchs et ports, dans l'ordre du croquis Switch.dc.html.

/// Couleurs propres aux sources de localisation (croquis).
enum SwitchSource: String {
    case lldp = "LLDP", cdp = "CDP", fdb = "FDB", arp = "ARP", uplink = "Uplink"

    var colors: (background: Color, foreground: Color) {
        switch self {
        case .lldp: return (Color(hex: 0xDBEAFE), Color(hex: 0x1E40AF))
        case .cdp: return (Color(hex: 0xE0E7FF), Color(hex: 0x3730A3))
        case .fdb: return (Theme.neutralSoft, Theme.neutralText)
        case .arp: return (Theme.successSoft, Color(hex: 0x166534))
        case .uplink: return (Color(hex: 0xE2E8F0), Color(hex: 0x0F172A))
        }
    }
}

struct SwitchSourceTag: View {
    let source: SwitchSource

    var body: some View {
        Text(source.rawValue)
            .font(Theme.mono(11, weight: .semibold))
            .foregroundStyle(source.colors.foreground)
            .padding(.horizontal, 6)
            .frame(height: 18)
            .background(RoundedRectangle(cornerRadius: Theme.chipRadius).fill(source.colors.background))
            .fixedSize()
    }
}

/// Étiquette de champ : 11 pt, majuscules, gris.
struct SwitchFieldLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(Theme.captionSemibold)
            .foregroundStyle(Theme.textSecondary)
    }
}

/// Champ de saisie aux couleurs des croquis.
struct SwitchTextFieldStyle: ViewModifier {
    var mono = true

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(mono ? Theme.mono(13) : Theme.body)
            .padding(.horizontal, 10)
            .frame(height: Theme.controlHeight)
            .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: Theme.buttonRadius).strokeBorder(Theme.border))
    }
}

// MARK: - Sources de localisation et interrogation

struct SwitchSourcesPanel: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var store: SwitchStore

    var body: some View {
        Panel(padding: 14) {
            HStack(alignment: .center, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Comment l’appareil est localisé").font(Theme.bodySemibold)
                    SwitchFlowLayout(spacing: 8) {
                        source(.lldp, "voisins annoncés")
                        source(.cdp, "équipements Cisco · bientôt")
                        source(.fdb, "table MAC par SNMP v2c · BRIDGE-MIB / Q-BRIDGE-MIB")
                        source(.arp, arpText)
                    }
                    Text("Un port d’accès qui apprend la MAC est retenu en priorité\u{00A0}; les ports trunk et uplink (voisin LLDP ou nombreuses MAC) sont ignorés.")
                        .font(Theme.small)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .bottom, spacing: 10) {
                        VStack(alignment: .leading, spacing: 4) {
                            SwitchFieldLabel("Version")
                            HStack(spacing: 6) {
                                Text("SNMP v2c").font(Theme.body)
                                Spacer(minLength: 4)
                                Chip(text: "v3 bientôt", tone: .neutral)
                            }
                            .padding(.horizontal, 10)
                            .frame(width: 168, height: Theme.controlHeight)
                            .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.panelMuted))
                            .overlay(RoundedRectangle(cornerRadius: Theme.buttonRadius).strokeBorder(Theme.border))
                            .help("SNMP v3 (authPriv) n’est pas encore implémenté dans cette version.")
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            SwitchFieldLabel("Communauté (lecture)")
                            SecureField("", text: $store.community, prompt: Text("à saisir").foregroundStyle(Theme.textTertiary))
                                .modifier(SwitchTextFieldStyle())
                                .frame(width: 170)
                                .onSubmit { store.poll(state: state) }
                        }
                        Button { store.poll(state: state) } label: {
                            HStack(spacing: 6) {
                                if store.isPolling {
                                    ProgressView().controlSize(.small).tint(.white)
                                } else {
                                    Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 12, weight: .semibold))
                                }
                                Text(store.isPolling ? "Interrogation…" : "Interroger les switchs")
                            }
                        }
                        .buttonStyle(.primary)
                        .disabled(!store.canPoll)
                        .opacity(store.canPoll || store.isPolling ? 1 : 0.5)
                        .help(pollHelp)
                    }
                    statusLine
                }
                .fixedSize()
            }
        }
    }

    private var arpText: String {
        if let gateway = state.activeInterface?.gateway { return "passerelle \(gateway) (MAC → IP)" }
        return "scan et tables ARP des switchs (MAC → IP)"
    }

    private var pollHelp: String {
        if store.hosts.isEmpty { return "Ajoutez d’abord un switch." }
        if store.community.isEmpty { return "Saisissez la communauté SNMP en lecture seule." }
        return "Interroge chaque switch en SNMP v2c (UDP 161)."
    }

    @ViewBuilder private var statusLine: some View {
        let snapshots = store.orderedSnapshots
        let fdb = snapshots.reduce(0) { $0 + $1.fdb.count }
        let lldp = snapshots.reduce(0) { $0 + $1.neighbors.count }
        HStack(spacing: 4) {
            if let host = store.pollingHost {
                Text("Interrogation de")
                Text(host).font(Theme.mono(12)).foregroundStyle(Theme.text)
                Text("…")
            } else {
                Text("Dernier relevé\u{00A0}:")
                Text(store.lastPoll.map(SwitchText.dateTime) ?? "jamais").font(Theme.mono(12)).foregroundStyle(Theme.text)
                Text("· \(store.hosts.count) switch\(store.hosts.count > 1 ? "s" : "") · \(fdb) entrées FDB · \(lldp) voisins LLDP")
            }
        }
        .font(Theme.small)
        .foregroundStyle(Theme.textSecondary)
    }

    private func source(_ source: SwitchSource, _ text: String) -> some View {
        HStack(spacing: 6) {
            Text(source.rawValue).font(.system(size: 12, weight: .bold))
            Text(text).font(Theme.small)
        }
        .foregroundStyle(source.colors.foreground)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(source.colors.background))
        .fixedSize()
    }
}

// MARK: - Cartes des switchs

struct SwitchCard: View {
    @ObservedObject var store: SwitchStore
    let host: String

    var body: some View {
        let snapshot = store.snapshots[host]
        let active = (store.current?.id ?? store.selectedHost) == host
        Button { store.select(host: host) } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.neutralSoft)
                        Image(systemName: "rectangle.connected.to.line.below").font(.system(size: 15)).foregroundStyle(Theme.text)
                    }
                    .frame(width: 34, height: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) {
                            Text(snapshot?.displayName ?? host).font(Theme.mono(14, weight: .semibold)).foregroundStyle(Theme.text)
                            statusChip(snapshot)
                            if let role = snapshot?.system.location { Chip(text: role, tone: .neutral) }
                        }
                        Group {
                            if let snapshot {
                                Text("\(SwitchText.model(snapshot)) · ") + Text(host).font(Theme.mono(12)) + Text(" · \(SwitchText.portsSummary(snapshot))")
                            } else {
                                Text(store.errors[host] ?? "Pas encore interrogé · ") + Text(host).font(Theme.mono(12))
                            }
                        }
                        .font(Theme.small)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                if let snapshot {
                    HStack(alignment: .top, spacing: 10) {
                        metric("Firmware", SwitchText.firmware(snapshot.system.descr))
                        metric("Uptime", snapshot.system.uptimeText ?? "—")
                        metric("Marque", snapshot.system.brand ?? "—", mono: false)
                        let physical = snapshot.physicalPorts
                        metric("Ports actifs", "\(physical.filter(\.isUp).count) / \(physical.count)")
                    }
                    poe(snapshot)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Theme.panelRadius).fill(Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(active ? Theme.accent : Theme.border, lineWidth: active ? 2 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Retirer ce switch", role: .destructive) { store.removeHost(host) }
        }
    }

    @ViewBuilder private func statusChip(_ snapshot: SNMPSwitchSnapshot?) -> some View {
        if store.pollingHost == host {
            Chip(text: "Interrogation…", tone: .accent)
        } else if store.errors[host] != nil {
            Chip(text: "Sans réponse", tone: .critical)
        } else if snapshot != nil {
            Chip(text: "En ligne", tone: .success)
        } else {
            Chip(text: "À interroger", tone: .neutral)
        }
    }

    private func metric(_ title: String, _ value: String, mono: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased()).font(Theme.caption).foregroundStyle(Theme.textSecondary)
            Text(value).font(mono ? Theme.mono(12) : Theme.small).foregroundStyle(Theme.text).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func poe(_ snapshot: SNMPSwitchSnapshot) -> some View {
        if let budget = snapshot.poeBudgetW, budget > 0 {
            let used = snapshot.poeUsedW ?? 0
            let fraction = Double(used) / Double(budget)
            VStack(spacing: 4) {
                HStack {
                    Text("PoE utilisé / budget")
                    Spacer()
                    Text("\(used)\u{00A0}W / \(budget)\u{00A0}W · \(Int((fraction * 100).rounded()))\u{00A0}%").font(Theme.mono(12)).foregroundStyle(Theme.text)
                }
                .font(Theme.small)
                .foregroundStyle(Theme.textSecondary)
                ProgressBar(fraction: fraction, color: fraction > 0.8 ? Theme.warning : Theme.accent)
            }
        } else {
            HStack {
                Text("PoE").font(Theme.small).foregroundStyle(Theme.textSecondary)
                Spacer()
                Text("non annoncé (POWER-ETHERNET-MIB absente)").font(Theme.small).foregroundStyle(Theme.textTertiary)
            }
        }
    }
}

/// Appareils du scan qui ressemblent à des switchs, à ajouter d'un clic.
struct SwitchCandidates: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var store: SwitchStore

    var body: some View {
        let candidates = store.candidates(from: state.devices)
        if !candidates.isEmpty {
            HStack(spacing: 8) {
                Text("Trouvés par le scan\u{00A0}:").font(Theme.small).foregroundStyle(Theme.textSecondary)
                ForEach(candidates.prefix(6)) { device in
                    Button { store.addHost(device.id) } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "plus").font(.system(size: 10, weight: .bold))
                            Text(device.id).font(Theme.mono(12))
                            Text(device.displayName).font(Theme.small).foregroundStyle(Theme.textSecondary)
                        }
                        .padding(.horizontal, 8)
                        .frame(height: 24)
                        .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.accentSoft))
                        .overlay(RoundedRectangle(cornerRadius: Theme.buttonRadius).strokeBorder(Color(hex: 0xBFDBFE)))
                        .foregroundStyle(Theme.accentStrong)
                    }
                    .buttonStyle(.plain)
                    .help(device.openPorts.contains(161) ? "Port 161 (SNMP) ouvert" : "Fabricant d’équipement réseau")
                }
                Spacer()
            }
        }
    }
}

// MARK: - Façade et recherche

struct SwitchFaceplatePanel: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var store: SwitchStore
    let snapshot: SNMPSwitchSnapshot

    var body: some View {
        let uplinks = snapshot.uplinkInterfaces()
        let ports = snapshot.physicalPorts
        let states = ports.map { SwitchPortState($0, snapshot: snapshot, uplinks: uplinks) }
        Panel(padding: 14) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 6) {
                    Text("Façade · ").font(.system(size: 14, weight: .semibold))
                        + Text(snapshot.displayName).font(Theme.mono(14, weight: .semibold))
                    Spacer()
                    stat("Actifs", states.filter { $0 != .down && $0 != .disabled }.count, Theme.successSoft, Color(hex: 0x14532D))
                    stat("PoE", states.filter { $0 == .poe }.count, Color(hex: 0xDBEAFE), Color(hex: 0x1E40AF))
                    stat("Trunk", states.filter { $0 == .trunk }.count, Color(hex: 0xE2E8F0), Color(hex: 0x0F172A))
                    stat("Erreurs", states.filter { $0 == .err }.count, Theme.criticalSoft, Theme.critical)
                    stat("Inactifs", states.filter { $0 == .down || $0 == .disabled }.count, Theme.neutralSoft, Theme.neutralText)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    SwitchFaceplate(snapshot: snapshot, selected: store.selectedPort,
                                    found: store.findResult?.host == snapshot.id ? store.findResult?.ifIndex : nil) { index in
                        store.select(host: snapshot.id, port: index)
                    }
                }
                SwitchLegend()
                Divider().overlay(Theme.border)
                findBlock
            }
        }
    }

    private func stat(_ label: String, _ value: Int, _ background: Color, _ foreground: Color) -> some View {
        (Text("\(label) ") + Text("\(value)").font(Theme.mono(12, weight: .bold)))
            .font(Theme.small)
            .foregroundStyle(foreground)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(background))
            .fixedSize()
    }

    private var findBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .bottom, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    SwitchFieldLabel("Trouver un appareil")
                    TextField("", text: $store.findQuery,
                              prompt: Text("IP, MAC ou hostname (ex. 10.182.122.111)").foregroundStyle(Theme.textTertiary))
                        .modifier(SwitchTextFieldStyle())
                        .onSubmit { store.find(store.findQuery, devices: state.devices) }
                }
                Button { store.find(store.findQuery, devices: state.devices) } label: {
                    Label("Localiser le port", systemImage: "mappin.and.ellipse")
                }
                .buttonStyle(.primary)
            }
            HStack(spacing: 6) {
                Text("Exemples\u{00A0}:").font(Theme.small).foregroundStyle(Theme.textSecondary)
                ForEach(examples, id: \.self) { example in
                    Button { store.find(example, devices: state.devices) } label: {
                        Text(example)
                            .font(Theme.mono(12))
                            .foregroundStyle(Theme.accentStrong)
                            .padding(.horizontal, 8)
                            .frame(height: 22)
                            .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.accentSoft))
                            .overlay(RoundedRectangle(cornerRadius: Theme.buttonRadius).strokeBorder(Color(hex: 0xBFDBFE)))
                    }
                    .buttonStyle(.plain)
                }
            }
            if let result = store.findResult {
                HStack(spacing: 8) {
                    Image(systemName: result.ok ? "checkmark" : "exclamationmark.circle").font(.system(size: 12, weight: .bold))
                    Text(result.text).font(Theme.body).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button { store.clearFind() } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }
                        .buttonStyle(.plain)
                        .help("Effacer le résultat")
                }
                .foregroundStyle(result.ok ? Color(hex: 0x14532D) : Color(hex: 0x9A3412))
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(result.ok ? Theme.successSoft : Theme.warningSoft))
            }
        }
    }

    /// Quelques appareils connus et localisables, pour essayer la recherche.
    private var examples: [String] {
        let snapshots = store.orderedSnapshots
        let located = state.devices.filter { device in
            guard let mac = device.mac else { return false }
            return SNMPLocator.locate(mac, in: snapshots) != nil
        }
        var result: [String] = []
        if let first = located.first(where: { $0.deviceType == .imprimante }) ?? located.first { result.append(first.id) }
        if let ap = located.first(where: { $0.deviceType == .pointAcces }), let mac = ap.mac { result.append(mac.formatted(.upperColon)) }
        if let named = located.first(where: { $0.deviceType == .iot }), let host = named.hostname?.split(separator: "-").first {
            result.append(String(host))
        }
        if let camera = located.first(where: { $0.deviceType == .camera }) { result.append(camera.id) }
        return Array(result.prefix(4))
    }
}

// MARK: - Détail du port

struct SwitchPortDetail: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var store: SwitchStore
    let snapshot: SNMPSwitchSnapshot
    let iface: SNMPInterface

    var body: some View {
        let uplinks = snapshot.uplinkInterfaces()
        let portState = SwitchPortState(iface, snapshot: snapshot, uplinks: uplinks)
        let entries = snapshot.entries(on: iface.index)
        let neighbor = snapshot.neighbor(on: iface.index)
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                SwitchFieldLabel("Port sélectionné · \(snapshot.displayName)")
                HStack(spacing: 8) {
                    Text(iface.name).font(Theme.mono(18, weight: .semibold))
                    Text(portState.label)
                        .font(Theme.captionSemibold)
                        .foregroundStyle(portState.badge.foreground)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: Theme.chipRadius).fill(portState.badge.background))
                }
                Text(iface.alias.isEmpty ? iface.descr : iface.alias).font(Theme.small).foregroundStyle(Theme.textSecondary)
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
            divider

            LazyVGrid(columns: [GridItem(.flexible(), alignment: .topLeading), GridItem(.flexible(), alignment: .topLeading)],
                      alignment: .leading, spacing: 10) {
                field("État admin / opér.", "\(iface.adminUp ? "Activé" : "Désactivé") / \(iface.operStatus.label)", mono: false)
                field("Vitesse", iface.isUp ? SNMPFormat.speed(mbps: iface.speedMbps) : "—")
                field("VLAN", vlanText(uplinks: uplinks))
                field("PoE", snapshot.poePorts.contains(iface.index) ? "Délivre du courant" : (iface.isUp ? "Aucune charge PoE" : "—"), mono: false)
                field("Entrée", SNMPFormat.bytes(iface.inOctets))
                field("Sortie", SNMPFormat.bytes(iface.outOctets))
                VStack(alignment: .leading, spacing: 2) {
                    Text("ERREURS EN ENTRÉE").font(Theme.caption).foregroundStyle(Theme.textSecondary)
                    let errors = iface.inErrors ?? 0
                    Text(iface.inErrors.map { SwitchText.grouped($0) } ?? "—")
                        .font(Theme.mono(12, weight: errors > 0 ? .semibold : .regular))
                        .foregroundStyle(errors >= 100 ? Theme.critical : Theme.text)
                }
                field("Dernier changement", SwitchText.lastChange(iface, uptime: snapshot.system.uptimeTicks), mono: false)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            divider

            VStack(alignment: .leading, spacing: 8) {
                SwitchFieldLabel("Appareils vus sur ce port (\(entries.count))")
                if entries.isEmpty {
                    Text("Aucune adresse MAC apprise sur ce port lors du dernier relevé.")
                        .font(Theme.small).foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.panelMuted))
                } else {
                    ForEach(entries.prefix(uplinks.contains(iface.index) ? 4 : 8), id: \.mac) { entry in
                        deviceRow(entry, neighbor: neighbor)
                    }
                    if entries.count > 8 || (uplinks.contains(iface.index) && entries.count > 4) {
                        Text("… et \(entries.count - (uplinks.contains(iface.index) ? 4 : 8)) autres (voir la table MAC)")
                            .font(Theme.small).foregroundStyle(Theme.textSecondary)
                    }
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            divider

            if let neighbor {
                VStack(alignment: .leading, spacing: 6) {
                    SwitchFieldLabel("Voisin LLDP")
                    inline("Système", neighbor.sysName, mono: true)
                    inline("Port distant", neighbor.portID + (neighbor.portDescr.map { $0 == neighbor.portID ? "" : " (\($0))" } ?? ""), mono: true)
                    inline("Capacités", neighbor.capabilities.map { $0.labels.joined(separator: ", ") } ?? "—", mono: false)
                    if let descr = neighbor.sysDescr {
                        inline("Plateforme", descr, mono: false)
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
                divider
            }

            let primary = entries.first.map { store.describe($0.mac, devices: state.devices) }
            SwitchFlowLayout(spacing: 8) {
                Button { if let ip = primary?.ip, ip != "—" { state.sendToPing(ip) } } label: {
                    Label("Ping continu", systemImage: "waveform.path.ecg")
                }
                .buttonStyle(.primary)
                .disabled(primary?.ip == nil || primary?.ip == "—")
                Button("Fiche appareil") { if let id = primary?.deviceID { state.showDevice(id) } }
                    .buttonStyle(.secondary)
                    .disabled(primary?.deviceID == nil)
                Button(store.copiedPort == iface.index ? "Copié" : "Copier les infos") { copy(entries: entries, neighbor: neighbor, portState: portState) }
                    .buttonStyle(.secondary)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: Theme.panelRadius).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
    }

    private var divider: some View { Rectangle().fill(Theme.border).frame(height: 1) }

    private func vlanText(uplinks: Set<Int>) -> String {
        let pvid = snapshot.pvid[iface.index]
        if uplinks.contains(iface.index) {
            let vlans = Set(snapshot.entries(on: iface.index).compactMap(\.vlan)).sorted()
            let list = vlans.isEmpty ? "" : " · " + vlans.map(String.init).joined(separator: ",")
            return "Trunk" + (pvid.map { " · natif \($0)" } ?? "") + list
        }
        return pvid.map { "Accès \($0)" } ?? "—"
    }

    private func field(_ title: String, _ value: String, mono: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased()).font(Theme.caption).foregroundStyle(Theme.textSecondary)
            Text(value).font(mono ? Theme.mono(12) : Theme.small).foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func inline(_ title: String, _ value: String, mono: Bool) -> some View {
        (Text("\(title)\u{00A0}: ").foregroundStyle(Theme.textSecondary) + Text(value).font(mono ? Theme.mono(12) : Theme.small))
            .font(Theme.small)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func deviceRow(_ entry: SNMPFDBEntry, neighbor: SNMPLLDPNeighbor?) -> some View {
        let info = store.describe(entry.mac, devices: state.devices)
        let isNeighbor = store.isAnnounced(entry.mac, by: neighbor, devices: state.devices)
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(info.name).font(Theme.bodySemibold).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 4)
                SwitchSourceTag(source: isNeighbor ? .lldp : .fdb)
            }
            Text("\(info.ip) · \(entry.mac.formatted(.upperColon))").font(Theme.mono(12)).foregroundStyle(Theme.text)
            Text("\(info.vendor) · VLAN \((entry.vlan ?? snapshot.pvid[iface.index]).map(String.init) ?? "—") · vu \(SwitchText.ago(snapshot.polledAt))")
                .font(Theme.small).foregroundStyle(Theme.textSecondary).lineLimit(1)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: Theme.buttonRadius).strokeBorder(Theme.border))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { if let id = info.deviceID { state.showDevice(id) } }
    }

    private func copy(entries: [SNMPFDBEntry], neighbor: SNMPLLDPNeighbor?, portState: SwitchPortState) {
        var lines = ["\(snapshot.displayName) · \(iface.name) · \(portState.label)"]
        if !iface.alias.isEmpty { lines.append(iface.alias) }
        lines.append("Vitesse\u{00A0}: \(SNMPFormat.speed(mbps: iface.speedMbps)) · VLAN\u{00A0}: \(snapshot.pvid[iface.index].map(String.init) ?? "—")")
        for entry in entries {
            let info = store.describe(entry.mac, devices: state.devices)
            lines.append("\(info.name) · \(info.ip) · \(entry.mac.formatted(.upperColon)) · \(info.vendor)")
        }
        if let neighbor { lines.append("Voisin LLDP\u{00A0}: \(neighbor.sysName) · \(neighbor.portID)") }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
        store.copiedPort = iface.index
        let index = iface.index
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if store.copiedPort == index { store.copiedPort = nil }
        }
    }
}

extension SwitchText {
    /// « 1 284 » (espace insécable comme séparateur de milliers).
    static func grouped(_ value: UInt64) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = "\u{00A0}"
        formatter.usesGroupingSeparator = true
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }
}

// MARK: - Table MAC / ports

struct SwitchMacTable: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var store: SwitchStore
    let snapshot: SNMPSwitchSnapshot

    struct Row: Identifiable {
        var id: String
        var ifIndex: Int
        var port: String
        var vlan: String
        var mac: String
        var ip: String
        var host: String
        var vendor: String
        var source: SwitchSource
    }

    private static let columns: [TableHeader.Column] = [
        .init(title: "Port", width: 86), .init(title: "VLAN", width: 50), .init(title: "MAC", width: 146),
        .init(title: "IP", width: 128), .init(title: "Hostname"), .init(title: "Fabricant", width: 112),
        .init(title: "Source", width: 70), .init(title: "Vu", width: 84),
    ]

    var body: some View {
        let rows = self.rows
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("Table MAC / ports").font(.system(size: 14, weight: .semibold))
                Text("\(rows.count) entrées · \(snapshot.displayName) · \(snapshot.fdb.contains { $0.vlan != nil } ? "Q-BRIDGE-MIB" : "BRIDGE-MIB")")
                    .font(Theme.small).foregroundStyle(Theme.textSecondary)
                Spacer()
                Toggle("Masquer les uplinks", isOn: $store.hideUplinks)
                    .toggleStyle(.checkbox)
                    .font(Theme.small)
                HStack(spacing: 6) {
                    Image(systemName: "line.3.horizontal.decrease").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                    TextField("", text: $store.tableFilter, prompt: Text("Filtrer port, VLAN, MAC, IP…").foregroundStyle(Theme.textTertiary))
                        .textFieldStyle(.plain)
                        .font(Theme.small)
                        .frame(width: 180)
                }
                .padding(.horizontal, 8)
                .frame(height: 28)
                .overlay(RoundedRectangle(cornerRadius: Theme.buttonRadius).strokeBorder(Theme.border))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Rectangle().fill(Theme.border).frame(height: 1)
            TableHeader(columns: Self.columns)
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(rows) { row in
                        rowView(row)
                    }
                    if rows.isEmpty {
                        Text(store.tableFilter.isEmpty ? "Aucune adresse MAC apprise." : "Aucune entrée ne correspond à «\u{00A0}\(store.tableFilter)\u{00A0}».")
                            .font(Theme.small).foregroundStyle(Theme.textSecondary)
                            .padding(20)
                    }
                }
            }
            .frame(height: 340)
        }
        .background(RoundedRectangle(cornerRadius: Theme.panelRadius).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
        .clipShape(RoundedRectangle(cornerRadius: Theme.panelRadius))
    }

    private var rows: [Row] {
        let uplinks = snapshot.uplinkInterfaces()
        let query = store.tableFilter.trimmingCharacters(in: .whitespaces).lowercased()
        var result: [Row] = []
        for entry in snapshot.fdb.sorted(by: { ($0.ifIndex ?? 0, $0.mac) < ($1.ifIndex ?? 0, $1.mac) }) {
            guard let i = entry.ifIndex else { continue }
            let isUplink = uplinks.contains(i)
            if isUplink && store.hideUplinks { continue }
            let info = store.describe(entry.mac, devices: state.devices)
            let neighbor = snapshot.neighbor(on: i)
            let source: SwitchSource = isUplink ? .uplink : (store.isAnnounced(entry.mac, by: neighbor, devices: state.devices) ? .lldp : .fdb)
            let row = Row(id: "\(i)-\(entry.mac)-\(entry.vlan ?? 0)", ifIndex: i, port: snapshot.interface(i)?.name ?? "\(entry.bridgePort)",
                          vlan: (entry.vlan ?? snapshot.pvid[i]).map(String.init) ?? "—", mac: entry.mac.formatted(.upperColon),
                          ip: info.ip, host: info.name, vendor: info.vendor, source: source)
            if !query.isEmpty {
                let hay = [row.port, row.vlan, row.mac, row.ip, row.host, row.vendor, row.source.rawValue].joined(separator: " ").lowercased()
                if !hay.contains(query) && !hay.contains(query.replacingOccurrences(of: "-", with: ":")) { continue }
            }
            result.append(row)
        }
        return result
    }

    private func rowView(_ row: Row) -> some View {
        let selected = store.selectedPort == row.ifIndex
        return HStack(spacing: 0) {
            cell(row.port, width: 86, mono: true)
            cell(row.vlan, width: 50, mono: true)
            cell(row.mac, width: 146, mono: true)
            cell(row.ip, width: 128, mono: true)
            cell(row.host, width: nil, mono: false)
            cell(row.vendor, width: 112, mono: false)
            SwitchSourceTag(source: row.source).padding(.horizontal, 8).frame(width: 70, alignment: .leading)
            cell(SwitchText.ago(snapshot.polledAt), width: 84, mono: false)
        }
        .frame(height: 30)
        .background(selected ? Theme.accentSoft : Color.clear)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.neutralSoft).frame(height: 1) }
        .contentShape(Rectangle())
        .onTapGesture { store.select(host: snapshot.id, port: row.ifIndex) }
    }

    @ViewBuilder private func cell(_ text: String, width: CGFloat?, mono: Bool) -> some View {
        let label = Text(text).font(mono ? Theme.mono(12) : Theme.small).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.tail)
            .padding(.horizontal, 8)
        if let width { label.frame(width: width, alignment: .leading) } else { label.frame(maxWidth: .infinity, alignment: .leading) }
    }
}

// MARK: - Topologie simplifiée

struct SwitchTopology: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var store: SwitchStore

    var body: some View {
        let chain = orderedChain
        Panel(padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text("Topologie").font(.system(size: 14, weight: .semibold))
                    Text("déduite par LLDP").font(Theme.small).foregroundStyle(Theme.textSecondary)
                }
                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        Image(systemName: "globe").font(.system(size: 13))
                        Text("Internet").font(Theme.bodyMedium)
                        Spacer()
                    }
                    .foregroundStyle(Theme.neutralText)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .frame(width: 230)
                    .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Color(hex: 0x9CA3AF), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                    link(nil, color: Color(hex: 0x9CA3AF), width: 2)
                    if let gateway = gatewayDevice {
                        node(title: gateway.hostname ?? gateway.displayName, subtitle: "\(gateway.id) · passerelle", mono: false, active: false, muted: true) {}
                        link(gatewayLink(chain.first), color: Theme.accent, width: 2)
                    }
                    ForEach(Array(chain.enumerated()), id: \.element.id) { position, snapshot in
                        node(title: snapshot.displayName, subtitle: "\(snapshot.id) · \(SwitchText.shortModel(snapshot))", mono: true,
                             active: store.current?.id == snapshot.id, muted: false) {
                            store.select(host: snapshot.id, port: uplinkPort(of: snapshot))
                        }
                        if position + 1 < chain.count {
                            link(linkText(snapshot, chain[position + 1]), color: Theme.accent, width: 4)
                        }
                    }
                    if chain.isEmpty {
                        Text("Aucun switch interrogé.").font(Theme.small).foregroundStyle(Theme.textSecondary).padding(.top, 8)
                    }
                    vlanBlocks
                        .padding(.top, 12)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var gatewayDevice: Device? {
        guard let gateway = state.activeInterface?.gateway else { return nil }
        return state.devices.first { $0.ip == gateway }
    }

    /// Switchs dans l'ordre des liens LLDP, en partant de celui qui voit la passerelle.
    private var orderedChain: [SNMPSwitchSnapshot] {
        let all = store.orderedSnapshots
        guard !all.isEmpty else { return [] }
        let gatewayName = gatewayDevice?.hostname?.lowercased()
        let root = all.first { s in s.neighbors.contains { $0.sysName.lowercased() == gatewayName } } ?? all[0]
        var result = [root]
        var queue = [root]
        while let current = queue.first {
            queue.removeFirst()
            for neighbor in current.neighbors {
                if let next = all.first(where: { $0.displayName.caseInsensitiveCompare(neighbor.sysName) == .orderedSame }),
                   !result.contains(where: { $0.id == next.id }) {
                    result.append(next)
                    queue.append(next)
                }
            }
        }
        result += all.filter { s in !result.contains { $0.id == s.id } }
        return result
    }

    private func gatewayLink(_ root: SNMPSwitchSnapshot?) -> String? {
        guard let root, let name = gatewayDevice?.hostname?.lowercased(),
              let neighbor = root.neighbors.first(where: { $0.sysName.lowercased() == name }) else { return nil }
        let local = neighbor.ifIndex.flatMap { root.interface($0)?.name } ?? "?"
        return "\(neighbor.portID) ↔ \(local) · trunk"
    }

    private func linkText(_ a: SNMPSwitchSnapshot, _ b: SNMPSwitchSnapshot) -> String? {
        guard let neighbor = a.neighbors.first(where: { $0.sysName.caseInsensitiveCompare(b.displayName) == .orderedSame }) else { return nil }
        let iface = neighbor.ifIndex.flatMap { a.interface($0) }
        let speed = iface.map { " · " + SNMPFormat.speed(mbps: $0.speedMbps) } ?? ""
        return "\(iface?.name ?? "?") ↔ \(neighbor.portID)\(speed)"
    }

    private func uplinkPort(of snapshot: SNMPSwitchSnapshot) -> Int? {
        snapshot.uplinkInterfaces().sorted().first
    }

    private func link(_ text: String?, color: Color, width: CGFloat) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: width / 2).fill(color).frame(width: width, height: 26)
            if let text { Text(text).font(Theme.mono(11)).foregroundStyle(Theme.textSecondary) }
        }
        .frame(height: 28)
    }

    @ViewBuilder private func node(title: String, subtitle: String, mono: Bool, active: Bool, muted: Bool, action: @escaping () -> Void) -> some View {
        let box = VStack(alignment: .leading, spacing: 2) {
            Text(title).font(mono ? Theme.mono(13, weight: .semibold) : Theme.bodySemibold).foregroundStyle(Theme.text)
            Text(subtitle).font(Theme.mono(11)).foregroundStyle(Theme.textSecondary).lineLimit(1)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .frame(width: 230, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.panelRadius).fill(active ? Theme.accentSoft : (muted ? Theme.panelMuted : Theme.panel)))
        .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(active ? Theme.accent : Theme.border, lineWidth: active ? 2 : 1))
        if muted {
            box
        } else {
            Button(action: action) { box.contentShape(Rectangle()) }.buttonStyle(.plain)
        }
    }

    /// Les deux VLAN qui portent le plus d'appareils sur des ports d'accès.
    @ViewBuilder private var vlanBlocks: some View {
        let counts = vlanCounts
        if !counts.isEmpty {
            HStack(alignment: .top, spacing: 8) {
                ForEach(counts.prefix(2), id: \.vlan) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("VLAN \(item.vlan)").font(Theme.captionSemibold).foregroundStyle(Theme.text)
                        Text("\(item.count) appareil\(item.count > 1 ? "s" : "") en accès").font(Theme.caption).foregroundStyle(Theme.textSecondary)
                        Text(item.ports).font(Theme.mono(11)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                    }
                    .padding(.top, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(alignment: .top) { Rectangle().fill(Color(hex: 0x9CA3AF)).frame(height: 2) }
                }
            }
            .frame(width: 250)
        }
    }

    private var vlanCounts: [(vlan: Int, count: Int, ports: String)] {
        var map: [Int: (Int, [String])] = [:]
        for snapshot in store.orderedSnapshots {
            let uplinks = snapshot.uplinkInterfaces()
            for entry in snapshot.fdb {
                guard let i = entry.ifIndex, !uplinks.contains(i), let vlan = entry.vlan ?? snapshot.pvid[i], vlan != 1 else { continue }
                var item = map[vlan] ?? (0, [])
                item.0 += 1
                if let name = snapshot.interface(i)?.name, item.1.count < 3, !item.1.contains(name) { item.1.append(name) }
                map[vlan] = item
            }
        }
        return map.map { (vlan: $0.key, count: $0.value.0, ports: $0.value.1.joined(separator: ", ")) }
            .sorted { $0.count > $1.count }
    }
}

/// Disposition en lignes qui passent à la ligne suivante quand la largeur manque (flex-wrap).
struct SwitchFlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, maxX: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: proposal.width ?? maxX, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
