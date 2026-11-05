import NetScopeCore
import SwiftUI

/// Note 82 : « 18 adresses exclues » à côté du total des plages cochées. L'infobulle dit pourquoi
/// (chaque plage exclue touchée, avec sa note) ; un clic ouvre Réglages › Sites et plages.
/// Rien n'est affiché si aucune adresse cochée n'est exclue.
struct ScanExcludedLabel: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var sites = SiteModel.shared

    var body: some View {
        let ranges = state.ranges.filter(\.isEnabled).compactMap { try? $0.parsed() }
        let exclusions = sites.activeExclusions
        let count = exclusions.excludedCount(in: ranges)
        if count > 0 {
            Button {
                RegNavigation.shared.section = .sites
                state.open(.reglages)
            } label: {
                Label("\(count)\u{00A0}adresse\(count > 1 ? "s" : "")\u{00A0}exclue\(count > 1 ? "s" : "")", systemImage: "nosign")
                    .font(Theme.small)
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(Theme.neutralSoft))
            }
            .buttonStyle(.plain)
            .fixedSize()
            .help(Self.help(exclusions.breakdown(in: ranges), siteName: sites.activeName))
            .accessibilityLabel("\(count) adresses exclues du scan")
        }
    }

    /// « Jamais sondées (ni ping, ni ARP actif, ni ports, ni SNMP, ni noms) — plages exclues de « Siège » : … ».
    static func help(_ parts: [(entry: ExcludedRange, count: Int)], siteName: String) -> String {
        let lines = parts.map { part in
            "• \(part.entry.text)" + (part.entry.note.isEmpty ? "" : " — \(part.entry.note)") + "\u{00A0}: \(part.count)\u{00A0}adresse\(part.count > 1 ? "s" : "")"
        }
        return (["Jamais sondées (ni ping, ni ARP actif, ni ports, ni SNMP, ni noms). Plages exclues de «\u{00A0}\(siteName)\u{00A0}»\u{00A0}:"]
                + lines + ["Clic\u{00A0}: Réglages › Sites et plages."]).joined(separator: "\n")
    }
}
