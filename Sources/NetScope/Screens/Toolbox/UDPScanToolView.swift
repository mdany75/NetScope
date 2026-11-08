import NetScopeCore
import SwiftUI

/// Note 69 : outil Scan de ports en « UDP ciblé » (Boîte à outils). Même état que la fiche
/// Appareil et la feuille du Scanner (UDPScanModel, par hôte) ; tableau propre à l'outil.
struct UDPScanToolSection: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var model = UDPScanModel.shared
    @Binding var target: String
    @ObservedObject var store: ToolStore
    @StateObject private var table = UDPResultsTable.makeModel(id: "outils.udp", showProto: false)

    private var host: String { target.trimmingCharacters(in: .whitespaces) }
    private var hostState: UDPHostState { model.state(for: host) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .bottom, spacing: 12) {
                    targetField
                    Spacer(minLength: 0)
                    launchControls
                }
                VStack(alignment: .leading, spacing: 10) {
                    targetField
                    HStack(spacing: 12) {
                        Spacer(minLength: 0)
                        launchControls
                    }
                }
            }
            if let error = hostState.error {
                ToolNotice(tone: .critical, message: error)
            }
            if hostState.isRunning || hostState.summary != nil {
                progressBlock
                UDPResultsTable(rows: hostState.rows, table: table, probedAt: hostState.isRunning ? nil : hostState.summary?.date)
                if let findings = hostState.summary?.findings, !findings.isEmpty {
                    UDPFindingsList(findings: findings)
                }
                hostFooter
            } else {
                Text("Une vraie requête par protocole, pas un paquet vide\u{00A0}: DNS 53 (version.bind), TFTP 69 (fichier inexistant), NTP 123 (mode 3, et 6 et 7 pour la sécurité), NetBIOS 137, SNMP 161 (découverte v3, v2c avec la communauté choisie), IPMI 623, SSDP 1900, SIP 5060 (OPTIONS) et mDNS 5353. «\u{00A0}Ouvert|filtré\u{00A0}» veut dire aucune réponse\u{00A0}; «\u{00A0}fermé\u{00A0}», un refus ICMP.")
                    .font(Theme.small).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var targetField: some View {
        ToolLabeledField(label: "Cible (IP ou nom d’hôte)") {
            ToolTextField(placeholder: "10.182.122.111", text: $target) { model.scan(host: host, store: store) }
                .frame(minWidth: 170, maxWidth: 260)
        }
    }

    private var launchControls: some View {
        HStack(spacing: 12) {
            UDPProbeOptionsMenu()
            Group {
                if hostState.isRunning {
                    Button("Arrêter") { model.cancel(host: host) }.buttonStyle(.secondary)
                } else {
                    Button("Lancer le scan UDP") { model.scan(host: host, store: store) }.buttonStyle(.primary)
                }
            }
            .fixedSize()
        }
    }

    private var progressBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if hostState.isRunning {
                    Text("En cours · \(hostState.done) / \(hostState.total) ports UDP · \(MonText.plural(hostState.partial.filter { $0.state == .open }.count, "ouvert", "ouverts"))")
                } else if let summary = hostState.summary {
                    // « ouvert|filtré » ne se coupe pas au « | » (gluon U+2060 de part et d'autre).
                    Text((summary.wasCancelled ? "Interrompu · " : "Terminé · ") + summary.summary.replacingOccurrences(of: "|", with: "\u{2060}|\u{2060}")
                         + (hostState.communityNote.map { " · SNMP\u{00A0}: \($0)" } ?? ""))
                }
                Spacer()
                if let summary = hostState.summary {
                    Text(ToolFormat.seconds(summary.duration)).font(Theme.mono(12))
                }
                Button("Copier CSV") { model.copyCSV(host: host) }
                    .buttonStyle(.secondary)
                    .controlSize(.small)
                    .disabled(hostState.summary == nil)
                ToolColumnsMenu(model: table)
            }
            .font(Theme.small)
            .foregroundStyle(Theme.textSecondary)
            ProgressBar(fraction: hostState.isRunning ? hostState.fraction : 1,
                        color: hostState.isRunning ? Theme.accent : Theme.success)
        }
    }

    @ViewBuilder private var hostFooter: some View {
        if let device = state.devices.first(where: { $0.ip.description == host || $0.hostname == host }) {
            HStack(spacing: 0) {
                Text("Hôte\u{00A0}: ").foregroundStyle(Theme.textSecondary)
                Button(device.ip.description) { state.showDevice(device.id) }
                    .buttonStyle(.secondary).controlSize(.small)
                Text(" · " + [device.displayName, device.mac?.formatted(.upperColon), device.switchLocation, device.vlan.map { "VLAN \($0)" }]
                    .compactMap { $0 }.joined(separator: " · "))
                    .foregroundStyle(Theme.textSecondary)
            }
            .font(Theme.small)
        }
    }
}
