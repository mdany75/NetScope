import NetScopeCore
import SwiftUI

/// Conditions des sondes « Licence bientôt expirée » et « Firmware pas à jour » (note 41) dans
/// l'éditeur.
struct MonFirmwareConditionFields: View {
    @Binding var probe: MonProbe
    @State private var daysText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if probe.kind == .licenseExpiring {
                let days = Int(probe.resourceLimit ?? MonProbe.defaultResourceLimit(.licenseExpiring))
                HStack(spacing: 6) {
                    Text("Alerte si une licence expire dans").font(Theme.small).foregroundStyle(Theme.text).fixedSize()
                    MonInput(placeholder: "\(days)", text: Binding(get: { daysText ?? "\(days)" }, set: { typed in
                        daysText = typed
                        guard let v = Int(typed.trimmingCharacters(in: .whitespaces)), (1...730).contains(v) else { return }
                        probe.resourceLimit = Double(v)
                    }), mono: true)
                    .onSubmit { daysText = nil }
                    .frame(width: 52)
                    Text("jours ou moins").font(Theme.small).foregroundStyle(Theme.text).fixedSize()
                }
                .onChange(of: probe.id) { _, _ in daysText = nil }
                Text("Une licence expirée est une panne. Contrats FortiGuard (antivirus, IPS, filtrage web…) et FortiCare lus par la FortiGate, relue au plus à chaque intervalle, en lecture seule.")
                    .font(Theme.caption).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Alerte quand une version plus récente est disponible\u{00A0}: FortiOS de la même branche (FortiGuard), FortiSwitch et FortiAP selon la liste recommandée par la FortiGate ou le même modèle ailleurs dans le parc. NetScope ne lance jamais la mise à jour.")
                    .font(Theme.small).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Nouveau type choisi : tout le parc, seuil de 30 jours, sans seuil de latence propre au ping,
    /// une lecture par heure suffit.
    static func prepare(_ probe: inout MonProbe) {
        guard probe.kind == .licenseExpiring || probe.kind == .firmwareOutdated else { return }
        probe.thresholds.latencyMs = nil
        probe.thresholds.lossPercent = nil
        probe.thresholds.failures = 1
        if probe.interval < 3600 { probe.interval = 3600 }
        if probe.kind == .licenseExpiring, probe.resourceLimit == nil { probe.resourceLimit = Double(MonFirmwareChecks.defaultDays) }
        if probe.target.trimmingCharacters(in: .whitespaces).isEmpty { probe.target = "*" }
    }
}
