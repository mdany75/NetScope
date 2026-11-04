import NetScopeCore
import SwiftUI

/// Conditions des sondes « Tunnel VPN tombé » et « Lien WAN dégradé » (note 39) dans l'éditeur.
struct MonWANConditionFields: View {
    @Binding var probe: MonProbe
    @State private var latencyText: String?
    @State private var jitterText: String?
    @State private var lossText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if probe.kind == .wanLink {
                let t = probe.wanThresholds ?? .standard
                HStack(spacing: 6) {
                    Text("Dégradé si latence >").font(Theme.small).foregroundStyle(Theme.text).fixedSize()
                    field($latencyText, value: t.latencyMs, range: 1...5000) { v in
                        let c = probe.wanThresholds ?? .standard
                        probe.wanThresholds = WANThresholds(latencyMs: v, jitterMs: c.jitterMs, lossPercent: c.lossPercent)
                    }
                    Text("ms, gigue >").font(Theme.small).foregroundStyle(Theme.text).fixedSize()
                    field($jitterText, value: t.jitterMs, range: 1...2000) { v in
                        let c = probe.wanThresholds ?? .standard
                        probe.wanThresholds = WANThresholds(latencyMs: c.latencyMs, jitterMs: v, lossPercent: c.lossPercent)
                    }
                    Text("ms ou perte >").font(Theme.small).foregroundStyle(Theme.text).fixedSize()
                    field($lossText, value: t.lossPercent, range: 0.1...100) { v in
                        let c = probe.wanThresholds ?? .standard
                        probe.wanThresholds = WANThresholds(latencyMs: c.latencyMs, jitterMs: c.jitterMs, lossPercent: v)
                    }
                    Text("%").font(Theme.small).foregroundStyle(Theme.text).fixedSize()
                }
                .onChange(of: probe.id) { _, _ in
                    latencyText = nil
                    jitterText = nil
                    lossText = nil
                }
                Text("Mesures des sondes SD-WAN de la FortiGate (ou SLA non respecté)\u{00A0}; un lien tombé est une panne. La FortiGate est relue au plus à chaque intervalle, en lecture seule.")
                    .font(Theme.caption).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Panne quand la FortiGate voit le tunnel tombé (aucune phase 2 montée), alerte quand une partie des phases 2 manque. «\u{00A0}*\u{00A0}»\u{00A0}: tous les tunnels site à site de toutes les FortiGate activées\u{00A0}; «\u{00A0}Siège / *\u{00A0}»\u{00A0}: ceux d’un site. Les serveurs d’accès distant sans client ne comptent pas.")
                    .font(Theme.small).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func field(_ text: Binding<String?>, value: Double, range: ClosedRange<Double>, apply: @escaping (Double) -> Void) -> some View {
        MonInput(placeholder: MonFormat.number(value), text: Binding(get: { text.wrappedValue ?? MonFormat.number(value) }, set: { typed in
            text.wrappedValue = typed
            guard let v = Double(typed.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")), range.contains(v) else { return }
            apply(v)
        }), mono: true)
        .onSubmit { text.wrappedValue = nil }
        .frame(width: 52)
    }

    /// Nouveau type choisi : tous les tunnels ou liens, seuils par défaut, sans seuil de latence
    /// propre au ping, une seule lecture ratée suffit pour un tunnel tombé.
    static func prepare(_ probe: inout MonProbe) {
        guard probe.kind == .vpnTunnel || probe.kind == .wanLink else { return }
        probe.thresholds.latencyMs = nil
        probe.thresholds.lossPercent = nil
        if probe.interval < 60 { probe.interval = 300 }
        if probe.kind == .wanLink, probe.wanThresholds == nil { probe.wanThresholds = WANStore.shared.thresholds }
        if probe.target.trimmingCharacters(in: .whitespaces).isEmpty { probe.target = "*" }
    }
}
