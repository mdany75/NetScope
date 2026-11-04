import NetScopeCore
import SwiftUI

/// Éditeur de sonde, « Actions d'alerte » : envoi hors du Mac (courriel, webhooks) de cette sonde.
/// La case (brouillon de l'éditeur, appliquée à « Enregistrer ») exclut ou inclut la sonde ; le
/// champ dit où partent ses alertes (Réglages › Alertes).
struct MonAlertChannelsRow: View {
    let probeID: UUID
    @Binding var isOn: Bool
    @EnvironmentObject private var state: AppState
    @ObservedObject private var alerts = AlertDispatcher.shared

    var body: some View {
        // Le résumé suit la case du brouillon : décochée, la sonde sera exclue à l'enregistrement.
        let summary: (text: String, active: Bool) = isOn || !alerts.settings.isEnabled
            ? alerts.channelSummary(forProbe: probeID) : ("Sonde exclue des alertes", false)
        HStack(spacing: 8) {
            ToolCheckbox(label: "Courriel, webhook", isOn: $isOn)
                .frame(width: 132, alignment: .leading)
            HStack(spacing: 6) {
                Image(systemName: summary.active ? "paperplane.fill" : "paperplane")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(summary.active ? Theme.accentStrong : Theme.textTertiary)
                Text(summary.text)
                    .font(Theme.caption)
                    .foregroundStyle(summary.active ? Theme.text : Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 2)
                Button {
                    RegNavigation.shared.section = .alertes
                    state.open(.reglages)
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.accentStrong)
                }
                .buttonStyle(.plain)
                .help("Ouvrir Réglages › Alertes")
                .fixedSize()
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.panelMuted))
            .overlay(RoundedRectangle(cornerRadius: Theme.buttonRadius).strokeBorder(Theme.border))
        }
        .help(summary.active ? "Les alertes de cette sonde partent aussi\u{00A0}: \(summary.text) (Réglages › Alertes)."
                             : "\(summary.text) (Réglages › Alertes).")
    }
}

/// Cellule « Alertes externes » du tableau des sondes (colonne facultative) : canaux de la sonde.
struct MonAlertChannelCell: View {
    let probeID: UUID
    @ObservedObject private var alerts = AlertDispatcher.shared

    var body: some View {
        let summary = alerts.channelSummary(forProbe: probeID)
        Text(summary.active ? summary.text : "—")
            .font(Theme.small)
            .foregroundStyle(summary.active ? Theme.text : Theme.textTertiary)
            .lineLimit(1)
            .truncationMode(.tail)
            .help(summary.text)
    }
}
