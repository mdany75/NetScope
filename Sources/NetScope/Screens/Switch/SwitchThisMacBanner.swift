import NetScopeCore
import SwiftUI

/// Encart « Ce Mac est branché sur… » de Switchs et ports, alimenté par la dernière capture
/// LLDP/CDP de la boîte à outils. Rien n'est affiché tant qu'aucune capture n'a abouti.
struct SwitchThisMacBanner: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var switches: SwitchStore
    @ObservedObject private var capture = ToolStore.shared.neighbors

    var body: some View {
        if let neighbor = capture.lastNeighbor {
            HStack(spacing: 12) {
                Image(systemName: "cable.connector")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Theme.success)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(Theme.successSoft))
                VStack(alignment: .leading, spacing: 2) {
                    (Text("Ce Mac est branché sur ").font(Theme.body)
                     + Text(neighbor.headline).font(Theme.mono(13, weight: .semibold)))
                        .foregroundStyle(Color(hex: 0x14532D))
                        .lineLimit(1)
                    Text(detail(neighbor)).font(Theme.small).foregroundStyle(Color(hex: 0x166534)).lineLimit(1)
                }
                Spacer(minLength: 8)
                if switches.match(neighbor) != nil {
                    Button("Voir le port sur la façade") { switches.showNeighbor(neighbor) }
                        .buttonStyle(.secondary)
                }
                Button("Nouvelle capture") { ToolStore.shared.open(.lldp, in: state) }
                    .buttonStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Theme.panelRadius).fill(Color(hex: 0xF0FDF4)))
            .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Color(hex: 0xBBF7D0)))
        }
    }

    private func detail(_ neighbor: NetworkNeighbor) -> String {
        var parts = ["Reçu par \(neighbor.protocolLabel)"]
        if let interface = neighbor.interface { parts[0] += " sur \(interface)" }
        if let date = neighbor.receivedAt { parts[0] += " \(ToolText.relative(date))" }
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
