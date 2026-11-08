import NetScopeCore
import SwiftUI

/// Conditions des sondes de trafic (note 54) : seuil de charge du lien (%), seuil de débit d'un
/// appareil (Mb/s), ou base des menaces connues. Les sondes lisent FortiView en temps réel sur la
/// FortiGate du site actif, au plus à chaque intervalle, en lecture seule.
struct MonTrafficConditionFields: View {
    @Binding var probe: MonProbe
    @State private var text: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch probe.kind {
            case .linkSaturated, .heavyDevice:
                HStack(spacing: 6) {
                    Text(probe.kind == .linkSaturated ? "Alerte au-delà de" : "Alerte si un appareil dépasse")
                        .font(Theme.small).foregroundStyle(Theme.text).fixedSize()
                    MonInput(placeholder: MonFormat.number(MonProbe.defaultResourceLimit(probe.kind)),
                             text: Binding(get: { text ?? MonFormat.number(probe.resourceLimit ?? MonProbe.defaultResourceLimit(probe.kind)) },
                                           set: { typed in
                                               text = typed
                                               guard let value = Double(typed.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")),
                                                     value > 0, probe.kind == .heavyDevice || value <= 100 else { return }
                                               probe.resourceLimit = value
                                           }), mono: true)
                    .frame(width: 56)
                    Text(probe.kind == .linkSaturated ? "% de la capacité du lien" : "Mb/s")
                        .font(Theme.small).foregroundStyle(Theme.text).fixedSize()
                }
                .onChange(of: probe.id) { _, _ in text = nil }
                Text(probe.kind == .linkSaturated
                     ? "Capacité\u{00A0}: débits déclarés sur l’interface WAN de la FortiGate (estimated bandwidth), sinon la vitesse du port. La cause (appareil et application) est donnée dans l’alerte."
                     : "Débit mesuré par FortiView en temps réel\u{00A0}; l’application principale de l’appareil est donnée dans l’alerte.")
                    .font(Theme.caption).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            default:
                Text("Alerte à chaque menace jamais vue (IPS, antivirus, botnet, filtrage web), bloquée ou non"
                     + (probe.knownThreats.map { "\u{00A0}; \($0.count) menace\($0.count > 1 ? "s" : "") déjà connue\($0.count > 1 ? "s" : "")." }
                        ?? "\u{00A0}; les menaces présentes au premier passage servent de base."))
                    .font(Theme.small).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if probe.knownThreats != nil {
                    Button("Oublier les menaces connues") { probe.knownThreats = nil }
                        .buttonStyle(.secondary)
                        .fixedSize()
                }
            }
            Text("Droits «\u{00A0}FortiView\u{00A0}» et «\u{00A0}Log & Report\u{00A0}» en lecture nécessaires au profil de l’administrateur API.")
                .font(Theme.caption).foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
