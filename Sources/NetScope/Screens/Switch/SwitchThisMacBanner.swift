import NetScopeCore
import SwiftUI

/// Encart « Ce Mac est branché sur… » de Switchs et ports, alimenté par la dernière capture
/// LLDP/CDP de la boîte à outils. Rien n'est affiché tant qu'aucune capture n'a abouti.
/// L'encart dit quand et sur quelle interface la capture a été faite ; il se grise si cette
/// interface n’est plus active, si son lien a été coupé (câble déplacé) ou si son réseau
/// (sous-réseau, passerelle) a changé depuis.
struct SwitchThisMacBanner: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var switches: SwitchStore
    @ObservedObject private var capture = ToolStore.shared.neighbors
    /// Réseau actuel de l'interface de la capture (nil : interface inactive) ; relu toutes les 15 s.
    @State private var current: NetworkContext??

    /// Réseau de la capture : celui enregistré avec elle, sinon au moins son interface.
    private func captured(_ neighbor: NetworkNeighbor) -> NetworkContext? {
        capture.lastContext ?? neighbor.interface.map { NetworkContext(interface: $0) }
    }

    /// Avant la première lecture périodique, l'état est lu tout de suite : l'encart n'affirme rien
    /// au présent sans avoir vérifié l'interface (pas de bascule « est » → « était »).
    private func isStale(_ neighbor: NetworkNeighbor) -> Bool {
        guard let captured = captured(neighbor) else { return false }
        let now: NetworkContext? = current ?? captured.interface.flatMap { capture.currentContextNow(of: $0, active: state.activeInterface) }
        return captured.isStale(comparedTo: now)
    }

    var body: some View {
        if let neighbor = capture.lastNeighbor {
            let stale = isStale(neighbor)
            content(neighbor, stale: stale)
                .task(id: "\(captured(neighbor)?.interface ?? "") \(state.activeInterface?.address.description ?? "")") {
                    guard let name = captured(neighbor)?.interface else { return }
                    while !Task.isCancelled {
                        current = .some(await capture.currentContext(of: name, active: state.activeInterface))
                        try? await Task.sleep(nanoseconds: 15_000_000_000)
                    }
                }
        }
    }

    private func content(_ neighbor: NetworkNeighbor, stale: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "cable.connector")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(stale ? Theme.textSecondary : Theme.success)
                .frame(width: 30, height: 30)
                .background(Circle().fill(stale ? Theme.panelMuted : Theme.successSoft))
            VStack(alignment: .leading, spacing: 2) {
                (Text(stale ? "Ce Mac était branché sur " : "Ce Mac est branché sur ").font(Theme.body)
                 + Text(neighbor.headline).font(Theme.mono(13, weight: .semibold)))
                    .foregroundStyle(stale ? Theme.textSecondary : Color(light: 0x14532D, dark: 0x9CE7BA))
                    .lineLimit(1)
                Text(detail(neighbor, stale: stale)).font(Theme.small)
                    .foregroundStyle(stale ? Theme.textSecondary : Color(light: 0x166534, dark: 0x9AE9B8)).lineLimit(1)
                    .help(detail(neighbor, stale: stale))
            }
            Spacer(minLength: 8)
            if !stale, switches.match(neighbor) != nil {
                Button("Voir le port sur la façade") { switches.showNeighbor(neighbor) }
                    .buttonStyle(.secondary)
            }
            Button("Nouvelle capture") { ToolStore.shared.open(.lldp, in: state) }
                .buttonStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.panelRadius).fill(stale ? Theme.panelMuted : Color(light: 0xF0FDF4, dark: 0x1B502B)))
        .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(stale ? Theme.border : Color(light: 0xBBF7D0, dark: 0x2B824A)))
    }

    private func detail(_ neighbor: NetworkNeighbor, stale: Bool) -> String {
        var head = "Capture \(neighbor.protocolLabel)"
        if let date = neighbor.receivedAt { head += " du \(SwitchText.dateTime(date))" }
        if let interface = captured(neighbor)?.label ?? neighbor.interface, !interface.isEmpty { head += " sur \(interface)" }
        if stale { return head + "\u{00A0}: le lien a été coupé, ou l’interface ou le réseau a changé depuis\u{00A0}; ce relevé n’est plus actuel. Refaites une capture." }
        var parts = [head]
        if let model = neighbor.model { parts.append(model) }
        if let address = neighbor.managementAddresses.first { parts.append("gestion \(address)") }
        if let poe = neighbor.poe { parts.append("PoE \(poe)") }
        return parts.joined(separator: " · ")
    }
}

extension SwitchStore {
    /// Switch relevé (et port de sa façade) qui correspond au voisin LLDP/CDP de ce Mac :
    /// même nom système (sans le domaine) ou même adresse de gestion.
    func match(_ neighbor: NetworkNeighbor) -> (host: String, port: Int?)? {
        func short(_ name: String) -> String { name.lowercased().split(separator: ".").first.map(String.init) ?? "" }
        let name = neighbor.systemName.map(short)
        for host in hosts {
            guard let snapshot = snapshots[host] else { continue }
            let sameName = name != nil && short(snapshot.displayName) == name
            guard sameName || neighbor.managementAddresses.contains(host) else { continue }
            let port = neighbor.portLabel.flatMap { label in
                snapshot.physicalPorts.first { $0.name == label || $0.descr == label }?.index
            }
            return (host, port)
        }
        return nil
    }

    /// Sélectionne ce switch et ce port sur la façade.
    func showNeighbor(_ neighbor: NetworkNeighbor) {
        guard let found = match(neighbor) else { return }
        select(host: found.host, port: found.port)
    }
}
