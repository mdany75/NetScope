import NetScopeCore
import SwiftUI

/// Réglages › Interface réseau : interfaces IPv4 actives (getifaddrs, aucun trafic) et choix de
/// celle qu'utilise NetScope (`AppState.activeInterface`, affichée dans la barre latérale).
struct RegInterfaceSection: View {
    @EnvironmentObject private var state: AppState
    @State private var interfaces: [LocalInterface] = []
    @State private var loading = false
    @State private var autoChoice = false
    @State private var vpnWarning = false

    var body: some View {
        RegPanel(title: "Interface réseau",
                 subtitle: "Interface utilisée pour envoyer les sondes ARP, ICMP et TCP. ARP et LLDP exigent d’être sur le même segment.",
                 accessory: {
                     Button {
                         Task { await reload() }
                     } label: { Label("Actualiser", systemImage: "arrow.clockwise") }
                         .buttonStyle(.secondary)
                         .disabled(loading)
                 }, content: {
                     if interfaces.isEmpty {
                         RegNotice(loading ? "Lecture des interfaces…" : "Aucune interface IPv4 active (Wi-Fi ou Ethernet).", tone: .neutral)
                     } else {
                         LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 10, alignment: .top)], alignment: .leading, spacing: 10) {
                             ForEach(interfaces, id: \.name) { card($0) }
                         }
                     }
                     note.padding(.top, 12)
                     VStack(spacing: 0) {
                         RegToggleRow(title: "Choisir l’interface selon la plage",
                                      detail: "Utilise l’interface directement connectée au réseau scanné.",
                                      isOn: $autoChoice, soon: true)
                         RegToggleRow(title: "Avertir quand le scan passe par un VPN",
                                      detail: "La découverte de couche 2 est alors impossible.",
                                      isOn: $vpnWarning, soon: true)
                     }
                     .padding(.top, 12)
                 })
        .task { await reload() }
    }

    private var note: some View {
        let kind = state.activeInterface?.kind
        let text: String
        switch kind {
        case .wifi?:
            text = "Wi-Fi : la découverte ARP fonctionne sur le réseau de l’interface ; les autres VLAN sont atteints en ICMP/TCP par la passerelle."
        case .ethernet?:
            text = "Ethernet : recommandé pour les scans complets. Le port de switch utilisé sera lu par LLDP au branchement."
        default:
            text = "Choisissez l’interface à utiliser ; elle s’affiche dans la barre latérale."
        }
        return RegNotice(text, tone: .neutral)
    }

    private func card(_ interface: LocalInterface) -> some View {
        let selected = state.activeInterface?.name == interface.name
        let gateway = selected ? state.activeInterface?.gateway : interface.gateway
        let subnet = interface.subnet
        return Button {
            var choice = interface
            if choice.gateway == nil, state.activeInterface?.name == interface.name { choice.gateway = state.activeInterface?.gateway }
            state.activeInterface = choice
            state.preferredInterfaceName = choice.name
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text(interface.name).font(Theme.mono(13, weight: .bold))
                    Text(interface.kind.label).font(Theme.small).foregroundStyle(Theme.textSecondary)
                    Spacer()
                    RegPill(text: selected ? "Utilisée" : "Connectée", tone: selected ? .accent : .success)
                }
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                    row("IP", interface.address.description, bold: true)
                    row("Masque", "\(interface.netmask) (/\(subnet.prefix))")
                    row("Réseau", subnet.description)
                    row("Diffusion", subnet.broadcast.description)
                    row("Passerelle", gateway?.description ?? "Non lue")
                    row("Hôtes", "\(RegFormat.count(Int(subnet.hostCount))) adresses utilisables")
                }
            }
            .foregroundStyle(Theme.text)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: Theme.panelRadius).fill(selected ? Theme.accentSoft : Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(selected ? Theme.accent : Theme.border))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func row(_ key: String, _ value: String, bold: Bool = false) -> some View {
        GridRow {
            Text(key).font(Theme.small).foregroundStyle(Theme.textSecondary).frame(width: 74, alignment: .leading)
            Text(value).font(Theme.mono(12, weight: bold ? .semibold : .regular)).textSelection(.enabled)
        }
    }

    private func reload() async {
        if RegEnvironment.isDemo {
            interfaces = [
                state.activeInterface ?? LocalInterface(name: "en0", address: IPv4Address("10.182.122.135")!,
                                                        netmask: IPv4Address("255.255.255.0")!, kind: .wifi),
                LocalInterface(name: "en7", address: IPv4Address("10.182.122.158")!,
                               netmask: IPv4Address("255.255.255.0")!, kind: .ethernet,
                               gateway: IPv4Address("10.182.122.1")!),
            ]
            return
        }
        loading = true
        interfaces = await LocalInterfaces.listWithKinds()
        loading = false
    }
}
