import NetScopeCore
import SwiftUI

/// Condition des sondes de ressources (note 21) : seuil en pourcentage et, pour « Port saturé »,
/// le nom du port. La cible est « ce Mac » (lecture locale) ou l'adresse d'un agent SNMP.
struct MonResourceConditionFields: View {
    @Binding var probe: MonProbe

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(prefix).font(Theme.small).foregroundStyle(Theme.text).fixedSize()
                if probe.kind == .portLoad {
                    MonInput(placeholder: "port (Gi1/0/48, en0)", text: portText, mono: true)
                    Text(">").font(Theme.small).foregroundStyle(Theme.text).fixedSize()
                }
                MonInput(placeholder: MonFormat.number(MonProbe.defaultResourceLimit(probe.kind)), text: limitText, mono: true)
                    .frame(width: 64)
                Text(probe.kind == .portLoad ? "%\u{00A0}du lien" : "%").font(Theme.small).foregroundStyle(Theme.text).fixedSize()
            }
            Text(note)
                .font(Theme.caption).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var prefix: String {
        switch probe.kind {
        case .cpu: return "Alerte si le processeur dépasse"
        case .memory: return "Alerte si la mémoire dépasse"
        default: return "Alerte si"
        }
    }

    private var note: String {
        let local = MonResourceChecks.isLocal(probe.target)
        switch probe.kind {
        case .cpu:
            return local ? "Ce Mac\u{00A0}: charge mesurée sur 3\u{00A0}s, lecture locale, aucun trafic."
                : "SNMP v2c (communauté des Réglages › Identifiants)\u{00A0}: HOST-RESOURCES-MIB, sinon MIB Cisco, Fortinet ou HPE."
        case .memory:
            return local ? "Ce Mac\u{00A0}: mémoire utilisée comme le Moniteur d’activité\u{00A0}; une pression critique alerte aussi."
                : "SNMP v2c\u{00A0}: hrStorageRam (HOST-RESOURCES-MIB), sinon MIB Cisco, Fortinet ou HPE."
        default:
            return local ? "Ce Mac\u{00A0}: interface BSD (en0, en7…), débit mesuré sur 3\u{00A0}s."
                : "SNMP v2c\u{00A0}: IF-MIB (compteurs 64\u{00A0}bits si offerts), débit mesuré sur 3\u{00A0}s, nouvelles erreurs signalées."
        }
    }

    private var limitText: Binding<String> {
        Binding(get: { probe.resourceLimit.map(MonFormat.number) ?? "" },
                set: { text in
                    let cleaned = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
                    probe.resourceLimit = cleaned.isEmpty ? nil : Double(cleaned).map { min(100, max(0, $0)) } ?? probe.resourceLimit
                })
    }

    private var portText: Binding<String> {
        Binding(get: { probe.resourcePort ?? "" },
                set: { probe.resourcePort = $0.isEmpty ? nil : $0 })
    }

    /// Valeurs proposées au passage à un type de ressource : seuil par défaut, « ce Mac » si la
    /// cible est vide, et pas de seuil de latence ni de perte (sans objet).
    static func prepare(_ probe: inout MonProbe) {
        guard [.cpu, .memory, .portLoad].contains(probe.kind) else { return }
        if probe.resourceLimit == nil { probe.resourceLimit = MonProbe.defaultResourceLimit(probe.kind) }
        if probe.target.trimmingCharacters(in: .whitespaces).isEmpty { probe.target = "ce Mac" }
        probe.thresholds.latencyMs = nil
        probe.thresholds.lossPercent = nil
    }
}
