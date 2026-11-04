import NetScopeCore
import SwiftUI

/// Écran `Screen.outils` : boîte à outils du technicien (croquis docs/croquis/Toolbox.dc.html).
/// Liste des outils à gauche, outil choisi au centre, favoris, résultats récents et historique
/// des commandes à droite.
struct ToolboxScreen: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var store = ToolStore.shared

    var body: some View {
        ScrollView {
            HStack(alignment: .top, spacing: 16) {
                // La liste des outils descend jusqu'au bas de la colonne la plus haute.
                ToolListPanel(store: store)
                    .frame(width: 260)
                    .frame(maxHeight: .infinity, alignment: .top)
                SidePanelSplit(sideWidth: 260, collapse: .below, spacing: 16, collapseBelow: 720) {
                    ToolMainPanel(store: store)
                } side: {
                    ToolSidePanel(store: store)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, Theme.contentPadding)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .screenToolbar {
            Button {
                ToolActions.copy(store.recents.map { "\(ToolText.time($0.date))\t\($0.tool.label)\t\($0.target)\t\($0.summary)" }
                    .joined(separator: "\n"))
            } label: {
                Label("Copier les résultats", systemImage: "doc.on.doc")
            }
            .buttonStyle(.secondary)
            .disabled(store.recents.isEmpty)
            Button {
                state.open(.scanner)
            } label: {
                Label("Nouveau scan", systemImage: "magnifyingglass")
            }
            .buttonStyle(.primary)
        }
    }
}

// MARK: - Liste des outils

private struct ToolListPanel: View {
    @ObservedObject var store: ToolStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                ToolFieldLabel("Filtrer les outils")
                ToolTextField(placeholder: "ex. dns, mtu, lldp", text: $store.toolFilter, mono: false, height: 30)
            }
            .padding(.horizontal, 4)
            let groups = ToolKind.Group.allCases.map { group in (group, group.tools.filter { $0.matches(store.toolFilter) }) }
                .filter { !$0.1.isEmpty }
            ForEach(groups, id: \.0) { group, tools in
                VStack(alignment: .leading, spacing: 1) {
                    Text(group.rawValue.uppercased())
                        .font(Theme.captionSemibold).kerning(0.5)
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.horizontal, 8)
                        .padding(.bottom, 3)
                    ForEach(tools) { tool in row(tool) }
                }
            }
            if groups.isEmpty {
                Text("Aucun outil ne correspond à « \(store.toolFilter) ».")
                    .font(Theme.small).foregroundStyle(Theme.textSecondary).padding(8)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: Theme.panelRadius).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
    }

    private func row(_ tool: ToolKind) -> some View {
        let selected = store.selectedTool == tool
        return Button {
            store.selectedTool = tool
        } label: {
            HStack(spacing: 9) {
                Image(systemName: tool.symbol)
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 16)
                    .foregroundStyle(selected ? Theme.accentStrong : Theme.textSecondary)
                Text(tool.label)
                    .font(.system(size: 13, weight: selected ? .semibold : .medium))
                    .foregroundStyle(selected ? Theme.accentStrong : Theme.text)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if tool.redirect != nil {
                    Image(systemName: "arrow.up.forward").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.textTertiary)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 34)
            .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(selected ? Theme.accentSoft : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tool.summary)
    }
}

// MARK: - Zone principale

private struct ToolMainPanel: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var store: ToolStore
    @ObservedObject private var subnet = ToolStore.shared.subnet
    @ObservedObject private var mac = ToolStore.shared.mac
    @ObservedObject private var ports = ToolStore.shared.ports
    @ObservedObject private var dns = ToolStore.shared.dns
    @ObservedObject private var whois = ToolStore.shared.whois
    @ObservedObject private var wol = ToolStore.shared.wol
    @ObservedObject private var dhcp = ToolStore.shared.dhcp
    @ObservedObject private var neighbors = ToolStore.shared.neighbors

    var body: some View {
        let tool = store.selectedTool
        VStack(alignment: .leading, spacing: 0) {
            header(tool)
            VStack(alignment: .leading, spacing: 16) {
                content(tool)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: Theme.panelRadius).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
    }

    private func header(_ tool: ToolKind) -> some View {
        let command = self.command(for: tool)
        // Commande à droite du titre quand la place suffit ; sinon dessous, sur toute la largeur.
        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 12) {
                // Largeur idéale bornée : le résumé passe à la ligne plutôt que de chasser la commande.
                titleBlock(tool)
                    .frame(minWidth: 240, idealWidth: 280, maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 8)
                commandRow(command).frame(maxWidth: 320, alignment: .trailing)
            }
            VStack(alignment: .leading, spacing: 10) {
                titleBlock(tool)
                commandRow(command)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
    }

    private func titleBlock(_ tool: ToolKind) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ToolFieldLabel(tool.group.rawValue)
            Text(tool.label).font(.system(size: 16, weight: .bold)).foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
            Text(tool.summary).font(Theme.small).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func commandRow(_ command: String) -> some View {
        HStack(spacing: 8) {
            Text(command)
                .font(Theme.mono(12))
                .foregroundStyle(Theme.neutralText)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 8)
                .frame(height: 26)
                .background(RoundedRectangle(cornerRadius: Theme.chipRadius).fill(Theme.neutralSoft))
                .overlay(RoundedRectangle(cornerRadius: Theme.chipRadius).strokeBorder(Theme.border))
                .layoutPriority(1)
            Button {
                ToolActions.copy(command)
            } label: {
                Image(systemName: "doc.on.doc").font(.system(size: 12))
            }
            .buttonStyle(.secondary)
            .help("Copier la commande équivalente")
        }
    }

    @ViewBuilder private func content(_ tool: ToolKind) -> some View {
        switch tool {
        case .subnet: SubnetCalculatorView(model: subnet, store: store)
        case .mac: MACConverterView(model: mac)
        case .ports: PortScanView(model: ports, store: store)
        case .dns: DNSLookupView(model: dns, store: store)
        case .whois: WhoisView(model: whois, store: store)
        case .mtu: MTUToolView()
        case .iperf, .speedtest: SpeedRedirectView(tool: tool)
        case .wol: WakeOnLANView(model: wol, store: store)
        case .dhcp: DHCPTestView(model: dhcp, store: store)
        case .lldp: NeighborCaptureView(model: neighbors, store: store)
        }
    }

    /// Commande équivalente affichée dans l'en-tête de l'outil.
    private func command(for tool: ToolKind) -> String {
        switch tool {
        case .subnet: return "ipcalc \(subnet.cidr.trimmingCharacters(in: .whitespaces))"
        case .mac: return "oui \(mac.text.trimmingCharacters(in: .whitespaces))"
        case .ports: return ports.command
        case .dns:
            return DNSLookup.command(for: dns.query.isEmpty ? "<nom>" : dns.query, type: dns.type, server: dns.effectiveServer)
        case .whois: return "whois \(whois.target)"
        case .mtu: return "ping -D -s 1472 \(state.activeInterface?.gateway?.description ?? "<cible>")"
        case .iperf: return "iperf3 -c <serveur> -P 4 -t 10"
        case .speedtest: return "speedtest"
        case .wol: return wol.command
        case .dhcp: return dhcp.command
        case .lldp: return neighbors.command
        }
    }
}

// MARK: - Panneau droit

private struct ToolSidePanel: View {
    @ObservedObject var store: ToolStore

    var body: some View {
        VStack(spacing: 12) {
            box {
                ToolFieldLabel("Favoris")
                VStack(spacing: 2) {
                    ForEach(ToolKind.favorites) { tool in
                        Button { store.selectedTool = tool } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "star.fill").font(.system(size: 10)).foregroundStyle(Color(hex: 0xF59E0B))
                                Text(tool.label).font(Theme.bodyMedium).foregroundStyle(Theme.text)
                                Spacer()
                            }
                            .padding(.horizontal, 6)
                            .frame(height: 30)
                            .background(RoundedRectangle(cornerRadius: Theme.buttonRadius)
                                .fill(store.selectedTool == tool ? Theme.neutralSoft : Color.clear))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            box {
                ToolFieldLabel("Résultats récents")
                if store.recents.isEmpty {
                    Text("Les résultats des outils apparaîtront ici.").font(Theme.small).foregroundStyle(Theme.textSecondary)
                }
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(store.recents.prefix(6))) { recent in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(recent.displayTitle).font(.system(size: 12, weight: .semibold))
                                Spacer()
                                Chip(text: recent.status.label, tone: recent.status.tone)
                            }
                            Text(recent.target).font(Theme.mono(12)).lineLimit(1)
                            Text(recent.summary).font(Theme.small).foregroundStyle(Theme.textSecondary)
                                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                            Text(ToolText.relative(recent.date)).font(Theme.caption).foregroundStyle(Theme.textSecondary)
                        }
                        .padding(.bottom, 8)
                        .overlay(alignment: .bottom) { Rectangle().fill(Theme.neutralSoft).frame(height: 1) }
                        .contentShape(Rectangle())
                        .onTapGesture { store.selectedTool = recent.tool }
                    }
                }
            }
            box {
                HStack {
                    ToolFieldLabel("Historique des commandes")
                    Spacer()
                    Button { ToolActions.copy(store.commands.joined(separator: "\n")) } label: {
                        Image(systemName: "doc.on.doc").font(.system(size: 11))
                    }
                    .buttonStyle(.secondary)
                    .controlSize(.small)
                    .help("Copier l’historique")
                    .disabled(store.commands.isEmpty)
                }
                VStack(alignment: .leading, spacing: 4) {
                    if store.commands.isEmpty {
                        Text("# aucune commande pour l’instant").font(Theme.mono(11)).foregroundStyle(Theme.consoleMuted)
                    }
                    ForEach(Array(store.commands.prefix(12).enumerated()), id: \.offset) { _, command in
                        (Text("$ ").foregroundColor(Theme.consolePrompt) + Text(command).foregroundColor(Theme.consoleText))
                            .font(Theme.mono(11))
                            .lineLimit(2)
                            .textSelection(.enabled)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.console))
            }
        }
    }

    private func box<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) { content() }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: Theme.panelRadius).fill(Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
    }
}

