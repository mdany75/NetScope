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
                // Trop de canaux pour la largeur de l'éditeur : « Courriel + 2 » plutôt qu'un texte
                // coupé (la liste complète reste dans l'aide au survol).
                ViewThatFits(in: .horizontal) {
                    summaryText(summary.text, active: summary.active).fixedSize()
                    summaryText(Self.compact(summary.text), active: summary.active).fixedSize()
                    summaryText(summary.text, active: summary.active)
                }
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

    private func summaryText(_ text: String, active: Bool) -> some View {
        Text(text)
            .font(Theme.caption)
            .foregroundStyle(active ? Theme.text : Theme.textSecondary)
            .lineLimit(1)
            .truncationMode(.tail)
    }

    /// « Courriel · Teams · JSON » → « Courriel + 2 ».
    static func compact(_ text: String) -> String {
        let parts = text.components(separatedBy: " · ")
        guard parts.count > 1 else { return text }
        return "\(parts[0]) + \(parts.count - 1)"
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
