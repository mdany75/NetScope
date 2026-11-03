import NetScopeCore
import SwiftUI

/// Écran `Screen.carte` : carte hiérarchique construite à partir du scan
/// (Internet → passerelle → switchs → points d'accès et groupes d'appareils), croquis docs/croquis/Topologie.dc.html.
struct TopologieScreen: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var model = InvModel.shared

    @State private var selectedID: String?
    /// nil : la carte s'ajuste à la place disponible.
    @State private var zoom: CGFloat?
    @State private var fitScale: CGFloat = 1
    @State private var showEndDevices = true
    @State private var showPortLabels = true

    var body: some View {
        let graph = TopoGraph.build(devices: state.devices, gateway: state.activeInterface?.gateway,
                                    conflictIPs: model.store.conflictIPs)
        let layout = graph.layout(hidden: { node in
            !showEndDevices && (node.kind == .groupe || node.kind == .appareil)
        })

        Group {
            if state.devices.isEmpty {
                EmptyState(systemImage: Screen.carte.symbol, title: "Aucun appareil à placer sur la carte",
                           message: "La carte se construit à partir du dernier scan : passerelle, switchs, points d’accès et groupes d’appareils par type.") {
                    Button { state.open(.scanner) } label: { Label("Ouvrir le scanner", systemImage: "magnifyingglass") }
                        .buttonStyle(.primary)
                }
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    tiles(graph)
                    HStack(alignment: .top, spacing: 14) {
                        mapPanel(graph, layout)
                        TopoAside(graph: graph, selectedID: $selectedID)
                            .frame(width: 320)
                    }
                    .frame(maxHeight: .infinity)
                }
                .padding(Theme.contentPadding)
            }
        }
        .screenToolbar {
            Button { state.open(.switchs) } label: { Label("Switchs et ports", systemImage: Screen.switchs.symbol) }
                .buttonStyle(.secondary)
            Button { state.open(.scanner) } label: { Label("Redécouvrir", systemImage: "arrow.clockwise") }
                .buttonStyle(.primary)
                .help("Relancer un scan depuis l’écran Scanner pour mettre la carte à jour")
        }
        .feedsInventory(state)
    }

    // MARK: Indicateurs

    private func tiles(_ graph: TopoGraph) -> some View {
        let devices = state.devices
        let online = devices.filter(\.isOnline).count
        let switches = graph.nodes.filter { $0.kind == .switch && !$0.isInferred }.count
        let inferred = graph.nodes.filter { $0.kind == .switch && $0.isInferred && $0.id != "sw:?" }.count
        let aps = graph.nodes.filter { $0.kind == .pointAcces }.count
        let gatewayFound = graph.node("passerelle")?.isInferred == false
        let links = graph.links
        let wireless = links.filter { $0.child.isWireless }.count
        let placed = devices.filter { $0.switchName != nil }.count
        let conflicts = model.store.conflictIPs.filter { ip in devices.contains { $0.ip == ip } }.sorted()

        var equipment: [String] = []
        if gatewayFound { equipment.append("1 passerelle") }
        equipment.append("\(switches) switch\(switches > 1 ? "s" : "")")
        if inferred > 0 { equipment.append("\(inferred) par nom") }
        equipment.append("\(aps) AP")

        return HStack(alignment: .top, spacing: 12) {
            InvTile(title: "Appareils agrégés", value: "\(devices.count)", subtitle: "\(online) vus récemment", valueSize: 19)
            InvTile(title: "Équipements réseau", value: "\((gatewayFound ? 1 : 0) + switches + aps)",
                    subtitle: equipment.joined(separator: " · "), valueSize: 19)
            InvTile(title: "Liens affichés", value: "\(links.count)",
                    subtitle: "\(links.count - wireless) filaires · \(wireless) Wi-Fi", valueSize: 19)
            InvTile(title: "Ports de switch connus", value: "\(placed)/\(devices.count)",
                    subtitle: placed == devices.count ? "Tous les appareils sont placés" : "\(devices.count - placed) sans port connu",
                    valueColor: placed == devices.count ? Theme.text : Theme.warning, valueSize: 19)
            InvTile(title: "Anomalies IP", value: "\(conflicts.count)",
                    subtitle: conflicts.isEmpty ? "Aucun conflit actif" : "Conflit " + conflicts.map { ".\($0.octets.3)" }.joined(separator: ", "),
                    valueColor: conflicts.isEmpty ? Theme.text : Theme.critical, valueSize: 19)
        }
    }

    // MARK: Carte

    private func mapPanel(_ graph: TopoGraph, _ layout: TopoGraph.Layout) -> some View {
        let scale = zoom ?? fitScale
        return VStack(spacing: 0) {
            HStack(spacing: 16) {
                HStack(spacing: 8) {
                    Text("DISPOSITION").font(Theme.captionSemibold).foregroundStyle(Theme.textSecondary)
                    Text("Hiérarchique").font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 10).frame(height: 24)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Theme.panel))
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.border))
                }
                HStack(spacing: 10) {
                    Text("CALQUES").font(Theme.captionSemibold).foregroundStyle(Theme.textSecondary)
                    Toggle("Appareils finaux", isOn: $showEndDevices).toggleStyle(.checkbox).font(Theme.small)
                    Toggle("Ports", isOn: $showPortLabels).toggleStyle(.checkbox).font(Theme.small)
                }
                Spacer()
                HStack(spacing: 6) {
                    zoomButton("minus", "Zoom arrière") { zoom = max(0.3, scale / 1.2) }
                    Text("\(Int((scale * 100).rounded())) %").font(Theme.mono(12, weight: .semibold)).frame(width: 46)
                    zoomButton("plus", "Zoom avant") { zoom = min(2, scale * 1.2) }
                    Button { zoom = nil } label: { Label("Ajuster", systemImage: "arrow.up.left.and.arrow.down.right") }
                        .buttonStyle(.secondary)
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 46)
            Rectangle().fill(Theme.border).frame(height: 1)

            GeometryReader { geometry in
                let fit = min((geometry.size.width - 16) / layout.width, (geometry.size.height - 16) / layout.height, 1.2)
                ScrollView([.horizontal, .vertical]) {
                    TopoCanvas(graph: graph, layout: layout, selectedID: $selectedID, showPortLabels: showPortLabels)
                        .frame(width: layout.width, height: layout.height)
                        .scaleEffect(scale, anchor: .topLeading)
                        .frame(width: layout.width * scale, height: layout.height * scale, alignment: .topLeading)
                        .frame(minWidth: geometry.size.width, minHeight: geometry.size.height)
                }
                .onAppear { fitScale = max(0.3, fit) }
                .onChange(of: fit) { _, value in fitScale = max(0.3, value) }
            }
            .background(Theme.panelMuted)

            legend
        }
        .background(RoundedRectangle(cornerRadius: Theme.panelRadius).fill(Theme.panel))
        .clipShape(RoundedRectangle(cornerRadius: Theme.panelRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func zoomButton(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.panel))
                .overlay(RoundedRectangle(cornerRadius: Theme.buttonRadius).strokeBorder(Theme.border))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 6) {
            InvFlowLayout(spacing: 11) {
                Text("LÉGENDE").font(Theme.captionSemibold).foregroundStyle(Theme.textSecondary)
                legendIcon(.internet, "Internet")
                legendIcon(.passerelle, "Passerelle")
                legendIcon(.switch, "Switch")
                legendIcon(.pointAcces, "Point d’accès")
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 3).strokeBorder(Theme.borderStrong).frame(width: 14, height: 11)
                        .background(RoundedRectangle(cornerRadius: 3).fill(Theme.panel).offset(x: 2, y: 2))
                    Text("Groupe agrégé")
                }
                Rectangle().fill(Theme.border).frame(width: 1, height: 14)
                HStack(spacing: 5) { Capsule().fill(TopoStyle.wire).frame(width: 22, height: 3); Text("Filaire") }
                HStack(spacing: 5) {
                    Path { path in path.move(to: .zero); path.addLine(to: CGPoint(x: 22, y: 0)) }
                        .stroke(TopoStyle.wifi, style: StrokeStyle(lineWidth: 2, dash: [4, 3]))
                        .frame(width: 22, height: 2)
                    Text("Wi-Fi")
                }
                HStack(spacing: 5) { StatusDot(tone: .critical, size: 7); Text("Conflit IP") }
                HStack(spacing: 5) { StatusDot(tone: .neutral, size: 7); Text("Hors ligne") }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .font(Theme.small)
            .foregroundStyle(Theme.neutralText)
            HStack(spacing: 6) {
                Image(systemName: "info.circle").font(.system(size: 11))
                Text("Carte construite à partir du scan ; les liens physiques exacts nécessitent SNMP/LLDP (écran Switchs et ports).")
                    .font(Theme.small)
                Button("Ouvrir Switchs et ports") { state.open(.switchs) }.buttonStyle(.ghost)
            }
            .foregroundStyle(Theme.textSecondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Theme.panelMuted)
        .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
    }

    private func legendIcon(_ kind: TopoNodeKind, _ title: String) -> some View {
        let style = TopoStyle.colors(kind: kind, type: nil)
        return HStack(spacing: 5) {
            Image(systemName: TopoStyle.symbol(kind: kind, type: nil)).font(.system(size: 9, weight: .semibold))
                .foregroundStyle(style.fg)
                .frame(width: 16, height: 16)
                .background(RoundedRectangle(cornerRadius: 4).fill(style.bg))
            Text(title)
        }
    }
}
