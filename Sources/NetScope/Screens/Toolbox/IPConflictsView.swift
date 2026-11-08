import NetScopeCore
import SwiftUI

// Boîte à outils › « Conflits d’adresses IP » (note 96, inspiré d'arpwatch) : même IP pour deux
// MAC, réponses ARP contradictoires (usurpation possible) et MAC qui change souvent d'IP, à partir
// de la table ARP de ce Mac, des scans, de la table ARP de la FortiGate et du journal de
// l'Inventaire. Rien n'est envoyé ; en démonstration, données fixes.
struct IPConflictsView: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var pirates = PirateStore.shared
    @State private var refresh = Date()

    var body: some View {
        let conflicts = pirates.ipConflicts(devices: state.devices, now: refresh)
        let critical = conflicts.filter(\.isCritical)
        let usurp = conflicts.filter { $0.kind == .arpContradictoire }.count
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                ToolStatTile(label: "Conflits", value: "\(critical.count)", detail: "IP avec plusieurs MAC",
                             valueColor: critical.isEmpty ? Theme.text : Theme.critical)
                ToolStatTile(label: "Usurpation possible", value: "\(usurp)", detail: "Réponses ARP contradictoires",
                             valueColor: usurp == 0 ? Theme.text : Theme.critical)
                ToolStatTile(label: "MAC instables", value: "\(conflicts.count - critical.count)", detail: "Changent souvent d’IP",
                             valueColor: conflicts.count == critical.count ? Theme.text : Theme.warning)
            }
            HStack {
                Text("Site «\u{00A0}\(SiteModel.shared.activeName)\u{00A0}» · table ARP de ce Mac, scans, FortiGate et Inventaire")
                    .font(Theme.small).foregroundStyle(Theme.textSecondary)
                Spacer(minLength: 8)
                Button("Relire") { refresh = Date() }
                    .buttonStyle(.secondary)
                    .controlSize(.small)
                    .help("Relit la table ARP de ce Mac et recalcule (lecture locale, rien n’est envoyé)")
            }
            if conflicts.isEmpty {
                Text("Aucun conflit d’adresse IP relevé.").font(Theme.body).foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity).padding(24)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(conflicts.enumerated()), id: \.element.id) { index, conflict in
                        if index > 0 { Rectangle().fill(Theme.border).frame(height: 1) }
                        row(conflict)
                    }
                }
                .background(RoundedRectangle(cornerRadius: Theme.panelRadius).fill(Theme.panel))
                .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
            }
            Spacer(minLength: 0)
        }
    }

    private func row(_ c: IPConflict) -> some View {
        let tone = c.isCritical ? Theme.critical : Theme.warning
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: c.kind == .macInstable ? "arrow.triangle.2.circlepath" : "exclamationmark.triangle")
                .font(.system(size: 14, weight: .semibold)).foregroundStyle(tone).frame(width: 18)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(c.ip?.description ?? c.macs.first?.formatted(.upperColon) ?? "—")
                        .font(Theme.mono(13, weight: .semibold)).foregroundStyle(Theme.text)
                    Text(c.kind.label).font(Theme.small.weight(.semibold)).foregroundStyle(tone)
                    if c.involvesGateway {
                        Text("Passerelle").font(Theme.caption.weight(.semibold)).foregroundStyle(Theme.critical)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Capsule().fill(Theme.criticalSoft))
                    }
                }
                Text(c.detail).font(Theme.small).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                if c.kind != .macInstable {
                    Text(c.macs.map { mac in
                        mac.formatted(.upperColon) + (PirateStore.vendor(mac).map { " (\($0))" } ?? "")
                    }.joined(separator: " · "))
                    .font(Theme.mono(11)).foregroundStyle(Theme.textSecondary)
                }
            }
            Spacer(minLength: 8)
            Text(c.lastSeen.formatted(date: .omitted, time: .shortened)).font(Theme.caption).foregroundStyle(Theme.textSecondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}
